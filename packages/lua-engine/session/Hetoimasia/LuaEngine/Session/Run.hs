{-# LANGUAGE OverloadedStrings #-}

-- | The session coordinator (LFE-13): the composition of one or two roles' VMs into one session, how
-- they start, advance, fail and stop together.
--
-- = What it does
--
-- 'runSession' makes the session's state first and hands its handle to the caller, then, on the calling
-- thread (the thread that owns the supervision control, because the driver's waits are supervised
-- ones):
--
-- 1. checks, before any Lua, what can be impossible (the first logical deadline on the clock);
-- 2. builds each selected role's VM, in nested scopes that release them in the opposite order and
--    stop each owner before the coordinator, pool and output it borrows: a module coordinator over the
--    session's pool, a data service, the facade, and a supervised scheduled owner that hosts instances;
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
-- = Who runs what
--
-- * The /application's thread/ (the caller) builds, validates, admits and drives. It is the only thread
--   that grants ticks, finalizes an owner that ended, and marks a role retired.
-- * Each /owner's thread/ runs the hooks the coordinator installs: the dispatch gate (it parks there),
--   and the escalation that reports an instance's failure. Both are brief and never wait for the
--   application's thread except for the tracking that was masked to be quick.
-- * Any thread may ask for a stop, an interruption or the terminal failure latch ('requestStop',
--   'latchTerminalFailure'). Each is one transaction on the state followed by non-blocking requests to the
--   owners.
--
-- = The invariants
--
-- * /Admission is closed before the stop is issued./ Every stop and failure is one 'step' of the
--   state: it closes the roles' admission and reports the owners to stop, and only then are they asked.
-- * /Nothing escapes tracking./ An admission is intended before it is issued and tracked before the
--   instance may run: the owner parks the new instance's first hook, and its failure report waits, until
--   the application's thread has recorded it. A role does not retire while an intent is outstanding.
-- * /A grant is either issued before a stop of the logical role or not at all/: the driver checks the
--   logical role's admission and issues the grant under a lock that the stop of that role passes through
--   before it asks the owner to stop.
-- * /No gate reopens./ The start gate opens in the transaction that records the last selected @init@;
--   a stop or failure that comes first shuts it for good.
-- * /Retired is actual./ A role retires when its owner's worker has ended (the VM closed, every
--   instance settled, every provider's retirement complete) and its coordinator has been closed and has
--   given back every slot and byte.
-- * /The first failure stays./ A role's failure latches once; later failures are accounted in the
--   engine report and cannot replace it.
--
-- = Where the policy lives
--
-- The transitions are pure ("Hetoimasia.LuaEngine.Session.State"); this module applies them, performs
-- the effects they report and observes the world. It adds no scheduling: the cadence, the FIFO order,
-- the tick and the required-failure latch are the Lua host's.
module Hetoimasia.LuaEngine.Session.Run
  ( runSession
  , Session
  , sessionStatus
  , sessionOutcomeNow
  , requestStop
  , latchTerminalFailure
  ) where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , displayException
  , finally
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Foldable (toList)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Content.Identity (ContentKey, rootKeyBytes)
import Hetoimasia.Content.Inventory (inventoryRootKey)
import Hetoimasia.Foundation.Log (Component, logError, logInfo, unsafeComponent)
import Hetoimasia.Foundation.Resource
  ( cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , composeCleanup
  , displayCleanupFailure
  , withResource
  , withResourceLabelled
  )
import Hetoimasia.Foundation.Time (Duration, Instant, deadlineReached, readInstant)
import Hetoimasia.Foundation.Worker (Completion (..), awaitCompletion)
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
import Hetoimasia.LuaEngine.Request (m1Requests)
import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.Harness
import Hetoimasia.LuaEngine.Session.Pacing
import Hetoimasia.LuaEngine.Session.State
import Hetoimasia.LuaEngine.Session.Timer (Timer, clearTimerWake, disposeTimer, newTimer, syncTimer, timerWoken)
import Hetoimasia.LuaEngine.Session.Types
import Hetoimasia.Runtime.Supervision
  ( Disposition (Required)
  , Recognition (Unrecognized)
  , WorkerPolicy (..)
  , awaitSupervised
  , supervisedWorker
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
  ( Escalation (Isolate)
  , InstanceAdmission (..)
  , InstanceBounds (..)
  , InstanceConfig (..)
  , InstanceFailure (failureInstance)
  , InstanceId (..)
  , InstancePhase (..)
  , InstanceSettlement (..)
  , InstanceSnapshot (..)
  , InstanceTicket
  , ShutdownDisposition (ShutdownSkippedNoInit)
  , Termination (terminationShutdown)
  , admitBehaviorInstance
  , defaultInstanceConfig
  , inspectInstance
  , pollInstance
  , releaseHeldInstance
  )
import Hetoimasia.Scripting.Lua.Owner (LibraryProfile (LibraryProfileM1), VmConfig (vmOwnerName), newModulePhase, vmProfileConfig)
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
  , grantScheduledStep
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

-- Applying events -----------------------------------------------------------------------------------

-- | The one primitive that changes the session: commit an event.
--
-- __Contract.__ In one STM transaction the pure 'step' changes everything the event means (the failure latch, the
-- phase, the gates, the markers 'stEarly' and 'stAccounted', the historical facts the event proves) and appends to
-- the queue of effects owed ('stOwed') the stops and the diagnostics the event owes. That is the commit
-- ('commitEvent'), and it is all a recovery or a cancellation path ever does: it never runs the queue, so a stop or a
-- diagnostic that blocks or raises cannot keep the path from the obligations that follow it.
--
-- A normal step ('applyEvent') commits and then runs the queue, masked. The queue is also run by the driver, by
-- stopper registration, and once, in the final teardown drain, after a cancellation has propagated out of every scope.
-- An effect that raises is recorded as a failure of the engine and the queue goes on; an interruption leaves a stop
-- owed and puts a diagnostic back, and is raised after the state is consistent. The stops run before the
-- diagnostics, so a diagnostic cannot delay an owner's stop.
applyEvent ∷ Session → Event → IO Answer
applyEvent session event = mask_ $ do
  answer ← commitEvent session event
  runOwed session
  pure answer

-- | Commit an event and tell the probe (the harness's boundary between a commit and its effects). It runs no effect.
commitEvent ∷ Session → Event → IO Answer
commitEvent session event = do
  answer ← commitSilently session event
  sessionProbe session (Committed (Text.unpack (eventName event)))
  pure answer

-- | Commit an event: the one transaction, nothing else. Recovery paths use this directly.
commitSilently ∷ Session → Event → IO Answer
commitSilently session event = atomically $ do
  current ← readTVar (sessionState session)
  let (next, found) = step event current
  writeTVar (sessionState session) next
  pure found

-- | Run the queue of effects owed until nothing runnable is left. A stop whose owner does not exist yet is not
-- runnable and stays owed; registering the owner's stopper makes it so.
runOwed ∷ Session → IO ()
runOwed session = do
  next ← atomically (claimOwed session)
  forM_ next $ \owed → perform owed >> runOwed session
  where
    perform owed = tryWithContext @SomeException (effect owed) >>= \case
      Right () → settle owed
      Left failure@(ExceptionWithContext _ raised)
        | isAsync failure → do
            -- an interruption leaves a stop owed and puts a diagnostic back, then goes on being raised
            case owed of
              OweSay _ → void (commitSilently session (Requeued owed))
              OweStop _ → pure ()
            rethrowIO failure
        | otherwise → do
            -- a failure of an effect is a failure of the engine, recorded without a diagnostic of its own when it
            -- was a diagnostic that failed; the effect is given up first, then the failure committed, and the
            -- loop that called us goes on with what is left: nothing here runs the queue
            settle owed
            void . commitSilently session $ case owed of
              OweSay _ → DiagnosticFailed (engineEntry HostFailure Nothing OnEngine ("a diagnostic could not be written: " <> Text.take 512 (Text.pack (displayException raised))))
              OweStop role → EngineFault (Just role) (engineEntry HostFailure (Just role) OnEngine ("the owner could not be asked to stop: " <> Text.take 512 (Text.pack (displayException raised))))
    settle owed = case owed of
      OweStop _ → void (commitSilently session (Settled owed))
      OweSay _ → pure () -- claimed when it was taken
    effect = \case
      OweStop role → do
        stoppers ← readTVarIO (sessionStoppers session)
        forM_ (Map.lookup role stoppers) $ \stopper → sessionProbe session (StopHandoff role) >> stopper
      OweSay (Say level message fields) ->
        (case level of SayInfo → logInfo; SayError → logError) (sessionLogger session) sessionComponent message fields

-- | Take the next effect that can be performed now: a diagnostic is claimed (it leaves the queue), a stop is left in
-- it until it has been performed.
claimOwed ∷ Session → STM (Maybe Owed)
claimOwed session = do
  state <- readTVar (sessionState session)
  stoppers <- readTVar (sessionStoppers session)
  let queue = toList (stOwed state)
  case find (runnable stoppers) (filter isStop queue) <|> find (runnable stoppers) queue of
    Just owed@(OweSay _) → do
      writeTVar (sessionState session) (fst (step (Settled owed) state))
      pure (Just owed)
    other → pure other

isStop ∷ Owed → Bool
isStop = \case
  OweStop _ → True
  OweSay _ → False

runnable ∷ Map.Map Role (IO ()) → Owed → Bool
runnable stoppers = \case
  OweSay _ → True
  OweStop role → Map.member role stoppers

-- | Whether some effect owed can be performed now.
hasRunnable ∷ Map.Map Role (IO ()) → SessionState → Bool
hasRunnable stoppers state = any (runnable stoppers) (toList (stOwed state))

-- | Run an action that writes a diagnostic the queue does not carry ("session starting", "session ended"). A failure
-- other than an interruption is recorded as a failure of the engine and not raised.
diagnose ∷ Session → IO () → IO ()
diagnose session action =
  tryWithContext @SomeException action >>= \case
    Right () → pure ()
    Left failure@(ExceptionWithContext _ raised)
      | isAsync failure → rethrowIO failure
      | otherwise →
          void . applyEvent session . DiagnosticFailed $
            engineEntry HostFailure Nothing OnEngine ("a diagnostic could not be written: " <> Text.take 512 (Text.pack (displayException raised)))

-- | The status the session publishes now: coherent, bounded and nonblocking. A reader that polls may
-- miss an intermediate phase; none is promised to be seen.
sessionStatus ∷ Session → STM SessionStatus
sessionStatus session = statusOf <$> readTVar (sessionState session)

-- | The outcome data the session holds now, failure over interruption over success: what a composing
-- application reports, as soon as a failure has latched, without waiting for the session to end.
sessionOutcomeNow ∷ Session → STM SessionOutcome
sessionOutcomeNow session = outcomeOf <$> readTVar (sessionState session)

-- | Ask for a stop. It takes no slot and cannot be refused: one transaction closes the whole session's
-- admission and its tick grants, and then each owner is asked to stop without waiting. Idempotent. A
-- failure that is already latched stays the outcome; an interruption outranks a normal quit.
requestStop ∷ Session → StopKind → IO ()
requestStop session kind = void (applyEvent session (Stop kind))

-- | Latch the terminal failure of the unavailable-state guard, and end the whole session. Answers
-- whether this was the first such failure, which is when the guard prints.
latchTerminalFailure ∷ Session → RoleFailure → IO Bool
latchTerminalFailure session failure = do
  limits ← stLimits <$> readTVarIO (sessionState session)
  answer ← applyEvent session (Terminal (boundFailure limits failure))
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
  }

-- | One role's VM and what it borrows.
data RoleVm = RoleVm
  { rvInfo ∷ !RoleInfo
  , rvCoordinator ∷ !Coordinator
  , rvOwner ∷ !ScheduledOwner
  , rvEndpoint ∷ !ScheduledEndpoint
  , rvFacade ∷ !Facade.Facade
  }

probeAt ∷ Env → Point → IO ()
probeAt env = harnessProbe (sxHarness (envSpec env))

stateOf ∷ Env → STM SessionState
stateOf = readTVar . sessionState . envSession

-- | The admission a role's facade reads before a content request starts.
admissionOf ∷ Env → Role → IO AdmissionState
admissionOf env role = do
  state ← readTVarIO (sessionState (envSession env))
  pure $ case roleAdmit role state of
    AdmitOpen → AdmissionOpen
    AdmitStopping → AdmissionStopping
    AdmitClosed → AdmissionClosed

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
-- once: the role's admission closes and its owner is asked to stop in the transition that records it, whatever a
-- provider is slow to retire, and the failure policy is applied (D-42). Every failure is isolated; the policy is the
-- coordinator's, and the instance is marked as told so that its settlement adds only what else failed.
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

-- | Run a body over one role's VM. The scopes nest as the owner needs them: the coordinator outside,
-- then the owner, which is stopped first, so a @shutdown@ that prints still finds its sink and its
-- content, and the pool, root and output the caller owns outside all of it.
withRoleVm ∷ Env → RoleInfo → (RoleVm → IO a) → IO a
withRoleVm env info body = do
  handles ← newRequestHandles
  requests ← either (refuse "the request policy" . Text.pack . show) pure (m1Requests profile handles)
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
  buildStep env role BuildCoordinator (withModuleCoordinator moduleSpec) $ \coordinator → do
    bank ← newByteBankFor profile
    service ← either (refuse "the data service" . Text.pack . show) pure (dataService requests (sxInventory spec) (sxPool spec) bank)
    buildStep env role BuildData (\use → use bank) $ \_ → do
      let endpoints =
            FacadeEndpoints
              { endpointAdmission = admissionOf env role
              , endpointFailure = \(EngineFailure text) →
                  void (applyEvent (envSession env) (EngineFault (Just role) (engineEntry HostFailure (Just role) OnEngine text)))
              , endpointClock = sxClock spec
              , endpointTick = readTVarIO holder >>= maybe (pure (harnessTickBase harness)) (\found → (+ harnessTickBase harness) <$> atomically (scheduledTick found))
              }
      facade ←
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
      buildStep env role BuildFacade (\use → use facade) $ \_ → do
        let base = (vmProfileConfig LibraryProfileM1) {vmOwnerName = "session-" <> roleWord role}
        config ← either (refuse "the facade's installation" . Text.pack . show) pure (installFacade facade [] [] base)
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
                }
        withOwner env info owned coordinator holder facade body
  where
    spec = envSpec env
    harness = sxHarness spec
    profile = sxProfile spec
    role = riRole info
    refuse what why = throwIO (SessionRefused (what <> " was refused: " <> why))

-- | A construction step: the resource it makes, a point after it is made, and a point after it is released.
-- The release of the step is the resource's own; a probe that raises at the point after it is a cleanup
-- failure, retained beside the body's.
buildStep ∷ Env → Role → BuildStep → ((a → IO b) → IO b) → (a → IO b) → IO b
buildStep env role which with use =
  withResourceLabelled
    (roleWord role <> " " <> Text.pack (show which))
    (pure ())
    (\_ → probeAt env (Released role which))
    (\_ → with (\made → probeAt env (Built role which) >> use made))

-- | Start a role's owner, register what stops it, run a body, and on every way out stop it and wait for
-- its worker to have ended before anything it borrows is released.
--
-- The wait is for arbitrary Lua segments and shutdown hooks, so it is interruptible and never runs under an
-- uninterruptible mask; but an interruption does not end it. Each is recorded and the wait goes on until
-- the worker has actually ended, and then what happened is raised in order: a cancellation, if one was
-- among them, as itself, and every other failure whole as evidence beside it.
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
  started ← startScheduledOwner (sxRuntime spec) owned
  case started of
    ScheduledUnavailable failure → rethrowIO failure
    ScheduledRejected → throwIO (SessionRefused "the owner was rejected")
    ScheduledEnded → throwIO (SessionRefused "the owner ended before it started")
    ScheduledStarted owner → do
      let endpoint = scheduledEndpoint owner
          -- What stops this role's owner: the logical role's stop passes through the grant lock first, so a
          -- grant is either issued before it or not at all; the coordinator is closed to withdraw what no
          -- worker has taken. Nothing here waits.
          stopOwner = do
            when (role == Gameplay) (withMVar (sessionGrantLock (envSession env)) (\() → pure ()))
            retireScheduled owner
            closeModuleCoordinator coordinator
          -- On the way out, whichever way: the gates close, and the owner is asked to stop until it has been. The stop
          -- is idempotent and its one blocking step is interruptible, so an interruption of it is recorded and the
          -- stop made again, never given up: an owner nobody asked to stop would end this scope's wait never.
          leaving = do
            closed ← tryWithContext @SomeException (commitEvent (envSession env) Unwind)
            (either (: []) (const []) closed <>) <$> untilStopped []
          untilStopped interruptions =
            tryWithContext @SomeException stopOwner >>= \case
              Right () → pure (reverse interruptions)
              -- only an interruption is made good by asking again; a failure of the stop itself is kept and not repeated
              Left interruption
                | isAsync interruption → untilStopped (interruption : interruptions)
                | otherwise → pure (reverse (interruption : interruptions))
      outcome ← tryWithContext @SomeException . restore $ do
        atomically (writeTVar holder (Just endpoint))
        loader ← maybe (throwIO (SessionRefused "the owner has no loader endpoint")) pure (scheduledLoaderEndpoint owner)
        attachLoader coordinator loader
        probeAt env (Built role BuildOwner)
        registerStopper env role stopOwner
        body RoleVm {rvInfo = info, rvCoordinator = coordinator, rvOwner = owner, rvEndpoint = endpoint, rvFacade = facade}
      stopped ← leaving
      interruptions ← awaitEnded restore owner
      -- However the scope is left, the owner's completion is accounted (once, whichever path finds it first) and the
      -- coordinator drained before anything the owner or its reads borrow is released and before the role can be
      -- published as retired. Both go on through interruptions, as the wait for the owner does.
      (completion, accounting) ← finalizeOwner (void . commitEvent (envSession env)) env info owner
      draining ← tryWithContext @SomeException (probeAt env (Draining role))
      drained ← awaitDrainedThrough restore coordinator
      released ← tryWithContext @SomeException (probeAt env (Released role BuildOwner))
      let failures = [f | Left f ← [outcome]] <> stopped <> interruptions <> accounting <> [f | Left f ← [draining]] <> drained <> [f | Left f ← [released]]
          -- what the owner ended with travels beside whatever is raised, whole
          evidence =
            [(cleanupFailureLabel item, cleanupFailureException item) | item ← completionCleanup completion]
              <> [("lua owner", failed) | Worker.Failed failed ← [completionResult completion]]
      case (outcome, failures) of
        (Right value, []) → pure value
        _ → do
          propagateAll failures evidence
          either rethrowIO pure outcome
  where
    spec = envSpec env
    role = riRole info

-- | Register what stops a role's owner. A stop that was owed before the owner existed is performed now.
registerStopper ∷ Env → Role → IO () → IO ()
registerStopper env role action = do
  atomically (modifyTVar' (sessionStoppers (envSession env)) (Map.insert role action))
  runOwed (envSession env)

-- | Wait for the role's coordinator to have drained: every read it started has returned what it reserved. The
-- coordinator is closed first (a stop does that), so nothing new starts. Interruptions are recorded in order and the
-- wait goes on.
awaitDrainedThrough ∷ (∀ x. IO x → IO x) → Coordinator → IO [ExceptionWithContext SomeException]
awaitDrainedThrough restore coordinator = go []
  where
    go interruptions =
      tryWithContext @SomeException (restore (atomically (awaitDrained coordinator))) >>= \case
        Right () → pure (reverse interruptions)
        Left interruption
          | isAsync interruption → go (interruption : interruptions)
          | otherwise → pure (reverse (interruption : interruptions))

-- | Wait for the owner's worker to have ended, whatever supervision has latched: its raw completion.
-- Interruptions are recorded in order and the wait goes on.
awaitEnded ∷ (∀ x. IO x → IO x) → ScheduledOwner → IO [ExceptionWithContext SomeException]
awaitEnded restore owner = go []
  where
    go interruptions =
      tryWithContext @SomeException (restore (atomically (void (awaitCompletion (supervisedWorker (scheduledSupervised owner)))))) >>= \case
        Right () → pure (reverse interruptions)
        Left interruption → go (interruption : interruptions)

-- | Raise what went wrong, in the order it happened, as one failure: a cancellation, if one was among
-- them, is the one that propagates, otherwise the first is, and every other is kept whole as cleanup
-- evidence beside it. Nothing to raise returns.
propagateAll ∷ [ExceptionWithContext SomeException] → [(Text, ExceptionWithContext SomeException)] → IO ()
propagateAll failures evidence = case lookup chosen indexed of
  Nothing → pure ()
  Just primary →
    composeCleanup (Just primary) ([("lua session", failure) | (index, failure) ← indexed, index /= chosen] <> evidence)
      >>= maybe (rethrowIO primary) rethrowIO
  where
    indexed = zip [0 ∷ Int ..] failures
    chosen = case [index | (index, failure) ← indexed, isAsync failure] of
      index : _ → index
      [] → 0

isAsync ∷ ExceptionWithContext SomeException → Bool
isAsync (ExceptionWithContext _ exception) = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- Running -------------------------------------------------------------------------------------------------

-- | Run one session to its end and answer how it came out.
--
-- The handle is given to the callback before any VM exists, so a stop, an interruption or a status read
-- can be wired to whoever needs them. The callback must not block. The call returns only once every role
-- has actually retired; what failed is in the outcome. A failure of the composition itself (a service that
-- is refused, an injected fault) is the outcome too, and a cancellation of the calling thread is raised again
-- after everything acquired has been released.
runSession ∷ SessionSpec → (Session → IO ()) → IO SessionOutcome
runSession spec onReady = do
  let limits = failureLimitsOf (sxProfile spec)
      -- A checkpoint that holds no entry for a role it selects makes a session of no roles that has already failed.
      (roles, refusal) = either (\why → ([], Just why)) (\found → (found, Nothing)) (rolesOf spec)
      counted = [(riRole info, riInstances info) | info ← roles]
  lock ← newMVar ()
  stoppers ← newTVarIO Map.empty
  cell ← newTVarIO (newSessionState limits counted)
  let session = Session cell stoppers (sxLogger spec) (harnessProbe (sxHarness spec)) lock
  ids ← newInstanceIds
  seen ← newTVarIO Set.empty
  tracked ← newTVarIO Map.empty
  let env = Env spec session limits ids seen tracked (Map.fromList [(riRole info, info) | info ← roles])
  onReady session
  diagnose session (logInfo (sxLogger spec) sessionComponent "session starting" [("roles", Text.intercalate "," (map (roleWord . riRole) roles))])
  result ← tryWithContext @SomeException $ case refusal of
    Just why → void (applyEvent session (EngineFault Nothing (engineEntry HostFailure Nothing OnEngine why)))
    Nothing → conduct env roles
  -- A failure of the composition is committed whole (the primary and every cleanup failure attached to it) before any
  -- effect runs, and a cancellation is remembered, not yet raised. Then the retirements are published and the queue is
  -- drained once, after the cancellation has propagated out of every scope; only then is anything raised.
  cancelled ← case result of
    Right () → pure Nothing
    Left failure
      | isAsync failure → pure (Just failure)
      | otherwise → Nothing <$ recordFailure env failure
  swept ← sweepRetired session
  drained ← collecting [runOwed session]
  let interrupted = filter isAsync (swept <> drained)
  case (cancelled, interrupted) of
    (Just failure, _) → composeCleanup (Just failure) [("lua session", other) | other ← swept <> drained] >>= maybe (rethrowIO failure) rethrowIO
    (Nothing, other : _) → rethrowIO other
    (Nothing, []) → pure ()
  diagnose session $ do
    ended ← atomically (outcomeOf <$> readTVar cell)
    logInfo
      (sxLogger spec)
      sessionComponent
      "session ended"
      [("verdict", Text.pack (show (outVerdict ended))), ("failures", Text.pack (show (length (outFailures ended))))]
  atomically (outcomeOf <$> readTVar cell)

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

-- | Mark every role not yet retired as retired. It runs only after every scope has been left, so whatever a role
-- acquired has been released: a role that was never built holds nothing.
sweepRetired ∷ Session → IO [ExceptionWithContext SomeException]
sweepRetired session = do
  state ← readTVarIO (sessionState session)
  collecting [void (commitEvent session (RoleRetired role)) | (role, found) ← Map.toList (stRoles state), rsPhase found /= Retired]

-- | Run each of these, whatever the others do: every failure, interruptions included, is collected in order and none
-- stops the rest. The caller raises or records what it collected.
collecting ∷ [IO ()] → IO [ExceptionWithContext SomeException]
collecting actions = fmap concat . forM actions $ \action →
  tryWithContext @SomeException action >>= \case
    Right () → pure []
    Left failure → pure [failure]

-- | A failure of the composition itself is the session's: a host failure of the engine, with whatever
-- cleanup failed beside it.
recordFailure ∷ Env → ExceptionWithContext SomeException → IO ()
recordFailure env failure = void (commitEvent (envSession env) (CompositionFailed (compositionEntries failure)))

-- | The primary failure of the composition and every cleanup failure attached to it, as the engine entries one event
-- commits together.
compositionEntries ∷ ExceptionWithContext SomeException → [EngineEntry]
compositionEntries failure@(ExceptionWithContext _ exception) =
  engineEntry HostFailure Nothing OnEngine (Text.pack (displayException exception)) : [cleanupEntry Nothing item | item ← cleanupOf failure]

-- | The cleanup failures an exception carries, as engine entries for a role.
cleanupOf ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)]
cleanupOf (ExceptionWithContext context _) =
  [(cleanupFailureLabel item, cleanupFailureException item) | item ← cleanupFailuresInContext context]

cleanupEntry ∷ Maybe Role → (Text, ExceptionWithContext SomeException) → EngineEntry
cleanupEntry role (label, ExceptionWithContext _ exception) =
  engineEntry CleanupFailure role OnCleanup (label <> ": " <> Text.pack (displayException exception))

-- | Build, validate, admit and drive.
conduct ∷ Env → [RoleInfo] → IO ()
conduct env roles = do
  preflight env roles >>= \case
    Just entry → void (applyEvent (envSession env) (EngineFault (entryRole entry) entry))
    Nothing → build roles []
  where
    entryRole = eeRole
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
-- delivers at the first of them is accounted once, and every wait after it is raw.
operate ∷ Env → [RoleVm] → IO ()
operate env vms =
  withResource (newTimer (sxTimer (envSpec env))) disposeTimer $ \timer → do
    driver ←
      Driver
        <$> newIORef Supervised
        <*> newIORef Nothing
        <*> newIORef Nothing
        <*> newIORef Set.empty
        <*> newIORef Set.empty
        <*> newIORef Set.empty
        <*> newIORef Set.empty
        <*> newIORef False
        <*> pure timer
    -- A failure of the driver itself (a probe, a stop that cannot be made, a defect) is recorded the moment it is
    -- raised, as the first failure it is, and the scopes then unwind with the gates closed; a cancellation is not
    -- recorded here and goes on, carrying whatever the owners ended with.
    tryWithContext @SomeException (conduct' driver) >>= \case
      Right () → pure ()
      Left failure
        | isAsync failure → rethrowIO failure
        | otherwise → recordFailure env failure
  where
    conduct' driver = do
      stopped ← isStopping env
      unless stopped (bootEntries env vms driver)
      stopped' ← isStopping env
      unless stopped' (forM_ vms (admitRole env))
      void (applyEvent (envSession env) AdmissionComplete)
      drive env vms driver

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
  granted ← applyEvent session (Intend role)
  unless (granted == Refused) $ do
    declared ←
      declareInstance (rvFacade vm) (riContent info) >>= \case
        Left refused → abandon Nothing >> throwIO (SessionRefused ("an instance could not be declared: " <> Text.pack (show refused)))
        Right found → pure found
    restore (probeAt env (Intended key)) `onFailure` abandon (Just (declaredId declared))
    admitted ← admitBehaviorInstance (rvEndpoint vm) (request declared) `onFailure` abandon (Just (declaredId declared))
    case admitted of
      InstanceAccepted identity ticket → do
        -- The owner may already be starting the instance; its first hook waits for the tracking below, so
        -- nothing it does can run before it is tracked, whatever lands in this window.
        let track = do
              atomically (modifyTVar' (envTracked env) (Map.insert identity (Held key identity ticket (declaredId declared))))
              void (commitSilently session (Tracked role))
        restore (probeAt env (Issued key)) `finally` track
        restore (probeAt env (Tracking key))
      other → do
        abandon (Just (declaredId declared))
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
    abandon identity = do
      forM_ identity (forgetInstance (rvFacade vm))
      void (commitSilently session (Abandoned role))
    onFailure action cleanup = tryWithContext @SomeException action >>= either (\failure → cleanup >> rethrowIO failure) pure

-- Driving ------------------------------------------------------------------------------------------------------

-- | Whether the driver's waits are supervised: they are until supervision latches a fatal failure, after
-- which every supervised wait raises it again and the drain waits on raw outcomes instead.
data Mode = Supervised | Raw

-- | What the driver does next.
data Next
  = NextStops
  | NextRelease ![Held]
  | NextOrigin !Instant
  | NextEnded !Role
  | NextRetire !Role
  | NextInit ![Held]
  | NextSettled ![Held]
  | NextWake
  | NextFinished
  | NextDone

-- | A grant that was issued and not yet accounted for, or one the scheduler answered full.
data InFlight = Granted | Full

-- | The driver's own state, which only the driver reads or writes.
data Driver = Driver
  { dvMode ∷ !(IORef Mode)
  , dvSchedule ∷ !(IORef (Maybe Schedule))
  , dvInFlight ∷ !(IORef (Maybe InFlight))
  , dvFinalized ∷ !(IORef (Set Role))
  , dvInit ∷ !(IORef (Set InstanceKey))
  , dvSettled ∷ !(IORef (Set InstanceKey))
  , dvReleased ∷ !(IORef (Set InstanceKey))
  -- ^ The held instances the driver has released.
  , dvOriginTaken ∷ !(IORef Bool)
  -- ^ Whether the schedule has been derived from the origin the start gate recorded.
  , dvTimer ∷ !Timer
  }

-- | The driver: wait for what happens, in one transaction composed with supervision, and act on it, until
-- every role has retired.
drive ∷ Env → [RoleVm] → Driver → IO ()
drive env vms driver = loop
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

-- | Supervision delivered a failure. If one of this session's owners has the fatal status, its own outcome will
-- be accounted when it is finalized, once; otherwise the failure was another worker's, and the session ends
-- because of it.
supervisionFailed ∷ Env → [RoleVm] → ExceptionWithContext SomeException → IO ()
supervisionFailed env vms failure = do
  -- A failure supervision latched ends the session whoever's it is: the gates close and every owner is asked to
  -- stop now, which also ends a wait for an entry whose owner can no longer evaluate it.
  void (commitEvent (envSession env) Unwind)
  statuses ← atomically (forM vms (\vm → Supervision.workerStatus (scheduledSupervised (rvOwner vm))))
  let ours = any isFatal statuses
  unless ours $
    void (commitEvent (envSession env) (CompositionFailed (compositionEntries failure)))
  where
    isFatal = \case
      Supervision.WorkerFatal _ → True
      _ → False

-- | The transaction the driver waits in. The first that applies is the answer: an owner that ended, a role
-- that can retire, an @init@ that succeeded, an instance that ended, whether every role has retired, the
-- timer's wake while ticks are due, a grant that has finished.
nextStep ∷ Env → [RoleVm] → Driver → IO (STM Next)
nextStep env vms driver = do
  finalized ← readIORef (dvFinalized driver)
  inited ← readIORef (dvInit driver)
  settled ← readIORef (dvSettled driver)
  schedule ← readIORef (dvSchedule driver)
  inFlight ← readIORef (dvInFlight driver)
  released ← readIORef (dvReleased driver)
  originTaken ← readIORef (dvOriginTaken driver)
  pure $ do
    held ← Map.elems <$> readTVar (envTracked env)
    state ← stateOf env
    stoppers ← readTVar (sessionStoppers (envSession env))
    -- A stop the session owes whose owner exists is performed first, so one whose performer was cancelled is not lost.
    let owing = hasRunnable stoppers state
        -- The dispatch gate opened: the instances held after their validation are released, together, unless
        -- their role has stopped taking work.
        toRelease =
          [ item
          | dispatchDecision state == Just True
          , not (stStopping state)
          , item ← held
          , hdKey item `Set.notMember` released
          , roleAdmit (ikRole (hdKey item)) state == AdmitOpen
          ]
        origin = if originTaken then Nothing else stOrigin state
    ended ← firstSTM [ended' vm | vm ← vms, riRole (rvInfo vm) `Set.notMember` finalized]
    retiring ← firstSTM [retire state vm | vm ← vms, riRole (rvInfo vm) `Set.member` finalized, rsPhaseOf state vm /= Retired]
    started ← catMaybes <$> mapM (observe inited Active) held
    stopped ← catMaybes <$> mapM (observeSettled settled) held
    open ← gameplayTakes env
    woken ← case (schedule, inFlight) of
      (Just _, Nothing) | open → timerWoken (dvTimer driver)
      _ → pure False
    outstanding ← case (inFlight, find ((== Gameplay) . riRole . rvInfo) vms) of
      (Just _, Just vm) → (,) <$> ((== 0) <$> ticksOutstanding (rvEndpoint vm)) <*> ownerEnded vm
      _ → pure (False, False)
    case () of
      _
        | owing → pure NextStops
        | not (null toRelease) → pure (NextRelease toRelease)
        | Just instant ← origin → pure (NextOrigin instant)
        | Just role ← ended → pure (NextEnded role)
        | Just role ← retiring → pure (NextRetire role)
        | not (null started) → pure (NextInit started)
        | not (null stopped) → pure (NextSettled stopped)
        | allRolesRetired state → pure NextDone
        | woken → clearTimerWake (dvTimer driver) >> pure NextWake
        | fst outstanding || snd outstanding → pure NextFinished
        | otherwise → retry
  where
    ended' vm = do
      done ← ownerEnded vm
      pure (if done then Just (riRole (rvInfo vm)) else Nothing)
    retire state vm = do
      drained ← (awaitDrained (rvCoordinator vm) >> pure True) `orElse` pure False
      let quiet = maybe True ((== 0) . rsIntents) (Map.lookup (riRole (rvInfo vm)) (stRoles state))
      pure (if drained && quiet then Just (riRole (rvInfo vm)) else Nothing)
    rsPhaseOf state vm = maybe Retired rsPhase (Map.lookup (riRole (rvInfo vm)) (stRoles state))
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

-- | The first of these that has an answer, retrying only if none has.
firstSTM ∷ [STM (Maybe a)] → STM (Maybe a)
firstSTM [] = pure Nothing
firstSTM (item : rest) = item >>= maybe (firstSTM rest) (pure . Just)

-- | Whether a role's owner has ended: its worker's raw completion, which supervision's latch never hides.
ownerEnded ∷ RoleVm → STM Bool
ownerEnded vm = (awaitCompletion (supervisedWorker (scheduledSupervised (rvOwner vm))) >> pure True) `orElse` pure False

-- | Act on what happened.
act ∷ Env → [RoleVm] → Driver → Next → IO ()
act env vms driver = \case
  NextDone → pure ()
  NextStops → runOwed session
  NextRelease items → forM_ items $ \item → do
    modifyIORef' (dvReleased driver) (Set.insert (hdKey item))
    void (releaseHeldInstance (hdTicket item))
    probeAt env (Resumed (hdKey item))
  NextOrigin origin → do
    writeIORef (dvOriginTaken driver) True
    startPacing origin
  NextEnded role → forM_ (vmOf role) $ \vm → do
    probeAt env (OwnerEnded role)
    (_, finalizing) ← finalizeOwner (void . applyEvent session) env (rvInfo vm) (rvOwner vm)
    closeModuleCoordinator (rvCoordinator vm)
    modifyIORef' (dvFinalized driver) (Set.insert role)
    -- the role is finalized whatever finalizing raised; a cancellation among it is raised first, otherwise the first
    case (filter isAsync finalizing, finalizing) of
      (found : _, _) → rethrowIO found
      (_, found : _) → rethrowIO found
      _ → pure ()
  NextRetire role → void (applyEvent session (RoleRetired role))
  NextInit items → forM_ items $ \item → do
    modifyIORef' (dvInit driver) (Set.insert (hdKey item))
    initSucceeded item
  NextSettled items → forM_ items $ \item →
    pollInstance (hdTicket item) >>= \case
      Nothing → pure ()
      Just settlement → do
        modifyIORef' (dvSettled driver) (Set.insert (hdKey item))
        already ← Set.member (hdKey item) <$> readIORef (dvInit driver)
        when (not already && initializedBy settlement) $ do
          modifyIORef' (dvInit driver) (Set.insert (hdKey item))
          initSucceeded item
  NextWake → do
    now ← readInstant (sxClock spec)
    schedule ← readIORef (dvSchedule driver)
    forM_ schedule $ \current → when (deadlineReached now (scDue current)) (grant current)
  NextFinished → do
    inFlight ← readIORef (dvInFlight driver)
    writeIORef (dvInFlight driver) Nothing
    case inFlight of
      Just Granted → account
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
    -- Grant the next tick: the check of the logical role's admission and the issuing are one step under
    -- the lock a stop of that role passes through, so a grant is either issued before the stop or not at all.
    grant current = forM_ (vmOf Gameplay) $ \vm → case nextTickNumber current of
      Left fault → void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine (pacingFaultText fault))))
      Right number → do
        probeAt env (GrantIntent number)
        answer ← withMVar (sessionGrantLock session) $ \() → do
          open ← atomically (gameplayTakes env)
          if open then Just <$> grantScheduledStep (rvEndpoint vm) (scTick current) else pure Nothing
        case answer of
          Nothing → pure ()
          Just (GrantAccepted _) → writeIORef (dvInFlight driver) (Just Granted) >> probeAt env (GrantIssued number)
          Just GrantFull → writeIORef (dvInFlight driver) (Just Full)
          Just GrantClosed → pure ()
          Just GrantNotPositive →
            void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine "a tick duration the manifest checked was not positive")))
    -- The tick has finished; its accounting (the endings it began, their shutdowns, their escalations and
    -- their retirements) is waited for before the next tick is granted, so no tick is granted after a
    -- failure that tick caused has been latched. A completed tick is not a commit.
    account = forM_ (vmOf Gameplay) $ \vm → do
      mode ← readIORef (dvMode driver)
      waited ← case mode of
        Raw → pure AccountingOwnerEnded
        Supervised →
          tryWithContext @SomeException (awaitScheduledAccounting (sxControl spec) (rvOwner vm)) >>= \case
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

-- | Finalize a role's owner, on whichever path finds it ended first (the driver, or the scope that leaves it): collect
-- its raw completion and read what the settlements of its instances prove, then commit all of it in one event
-- ('OwnerFinalized'): the claim that the completion is accounted (once, whichever path commits first), how the owner
-- ended (a failure of the host, a cancellation; an engine failure the facade already reported at its boundary is not
-- a new failure), every cleanup failure it retained, and the @init@s the settlements prove. Nothing is derived later
-- and no clock is read: an @init@ that succeeded is a historical fact the host keeps in the instance's shutdown
-- disposition, committed with the settlement that proves it. What reading a settlement raised is returned for the
-- caller to raise or record, and the commit is made whatever it was.
finalizeOwner ∷ (Event → IO ()) → Env → RoleInfo → ScheduledOwner → IO (Completion (), [ExceptionWithContext SomeException])
finalizeOwner commit env info owner = do
  completion ← atomically (awaitCompletion (supervisedWorker (scheduledSupervised owner)))
  held ← filter ((== role) . ikRole . hdKey) . Map.elems <$> readTVarIO (envTracked env)
  proven ← forM held $ \item →
    tryWithContext @SomeException (pollInstance (hdTicket item)) >>= \case
      Right (Just settlement) | initializedBy settlement → pure ([hdKey item], [])
      Right _ → pure ([], [])
      Left failure → pure ([], [failure])
  let entries =
        ( case completionResult completion of
            Worker.Succeeded _ → []
            Worker.Failed (ExceptionWithContext _ exception)
              | isJust (fromException exception ∷ Maybe EngineFailure) → []
              | otherwise → [engineEntry HostFailure (Just role) OnEngine (Text.pack (displayException exception))]
            Worker.Cancelled (ExceptionWithContext _ exception) →
              [engineEntry HostFailure (Just role) OnEngine ("the owner was cancelled: " <> Text.pack (displayException exception))]
        )
          <> [ engineEntry CleanupFailure (Just role) OnCleanup (cleanupFailureLabel item <> ": " <> Text.pack (displayCleanupFailure item))
             | item ← completionCleanup completion
             ]
  committed ← collecting [commit (OwnerFinalized role entries (concatMap fst proven))]
  pure (completion, concatMap snd proven <> committed)
  where
    role = riRole info

-- | Whether an instance's @init@ ever succeeded, which is a historical fact the host keeps in the instance's shutdown
-- disposition: it is "skipped, no init" exactly when the @init@ never succeeded, whatever the instance failed in
-- afterwards, and whatever the driver happened to see of it while it lived.
initializedBy ∷ InstanceSettlement → Bool
initializedBy settlement = terminationShutdown (resultTermination settlement) /= ShutdownSkippedNoInit
