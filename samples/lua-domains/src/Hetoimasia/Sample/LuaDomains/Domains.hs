-- | The two owners and the driver: a UI Lua VM owner and a gameplay Lua VM owner created under one
-- supervision boundary, and the loop that grants gameplay its ticks and commits each one (#498
-- requirements 2, 5, 7, 8 and 13), now with the failure, overload and stop paths of #499.
--
-- = The owners
--
-- One 'LuaRuntime', two scheduled owners, each with a VM of its own and nothing shared with the
-- other:
--
-- * the /gameplay/ owner, in 'GameplayDomain', whose behavior is a @Periodic@ instance on
--   @LogicalTicks 1@: its @update@ runs once in every tick the driver grants. It admits controls
--   logically and leases its instances' workspaces;
-- * the /UI/ owner, in 'InterfaceDomain', whose behavior is a @Periodic@ instance on an
--   @ElapsedEvery@ cadence, on the clock and timer the configuration supplies. It is granted control
--   and inspection of the gameplay owner and of nothing else.
--
-- Each has its own standard libraries, scheduling bounds, initial chunk and @vmPolicy@, over the one
-- registration of "Hetoimasia.Sample.LuaDomains.Registration". Gameplay is started first and the UI
-- second, and they are retired in the opposite order, UI first: the UI is the producer of
-- intentions and the reader of snapshots, so by the time gameplay stops nothing can still be
-- producing for it.
--
-- = A tick
--
-- 'stepTick' is the driver's one step:
--
-- 1. In one transaction, check the session is still running, wait while a control request is between the
--    assignment of its place and the engine's admission of it (the UI's bracket; the UI is never waited
--    for, and a UI that has ended is not waited for either), then seal the next unstarted tick of the
--    queue and make the tick's candidate from the committed world and the sealed intentions
--    ("Hetoimasia.Sample.LuaDomains.Candidate"). Admission and sealing are transactions on one variable,
--    so no intention is ever accepted for a tick that has started, and no control is given a tick that has.
-- 2. Grant gameplay one logical step of the configured duration. Grants are made one at a time, so
--    at most one is outstanding (P-6).
-- 3. Wait for the owner to complete the tick ('awaitTicksComplete').
-- 4. /Fence/. Completion of the tick says only that the grant was applied and nothing is left that
--    it could run: the scheduler reconciles the grant before the instance layer has accounted for what the
--    tick's last segment did, so an invocation that the scheduler ended with a refused wait still looks,
--    for a moment, like an instance that is active with nothing in flight. The driver therefore admits a
--    task that does nothing, and waits for its settlement. The owner's thread runs a segment and then the
--    boundary that follows it, one after the other, so the fence's segment begins only after every boundary
--    before it is over: the instance layer has accounted for the tick, an instance that failed has ended —
--    its @shutdown@ and the release of what it held included — and the application has been told. Only
--    then does the driver decide, and it never decides from the tick's completion alone.
-- 5. Decide. If a session failure has been told of, or a task the session admitted has faulted, nothing is
--    committed: the failure is published (below). If a stop was asked for, nothing is committed. Otherwise
--    the tick commits only if its work finished successfully: gameplay said so (@staging.finish()@) and
--    the instance is active with nothing in flight and no update owed, or the engine says why there is no
--    work to do (the behavior is paused, was paused when the tick began, or a control was applied at the
--    tick's boundary). Otherwise 'TickNotCompleted' is raised, nothing is committed, and the session is halted.
-- 6. To commit, in one transaction: replace the committed world, publish the snapshot (its status taken from
--    the engine's own inspection of the behavior, @Paused@ or @Running@), settle the tick's reservations and
--    count its dispositions. A reader sees the whole tick or none of it.
--
-- A tick held inside a segment (an example's barrier) is a driver that has not got past step 3: it
-- publishes nothing, so the snapshot always shows the last completed tick.
--
-- = A failure
--
-- A failure of script execution on the gameplay owner fails the session ("Hetoimasia.Sample.LuaDomains.Session"):
-- the instance's failure is told to the application by the owner's escalation callback, which records it and
-- answers 'Isolate', and the fault of a task the session admitted is found by the driver at the fence. From
-- the moment the driver knows of one, it grants nothing more and publishes @one@ snapshot for it: the last
-- good world and committed tick, status 'Failed' with the evidence, and the intentions the failure invalidated
-- (every accepted intention that had no committed terminal disposition, those of the failing tick, applied only
-- into its discarded batch or not, included). The owner and its VM stay alive, running nothing, until the stop.
--
-- = A stop
--
-- 'stopSession' is the one stop, from the driver. It ends admission and grants at once, asks the gameplay
-- behavior to stop and waits for it to be settled — its @shutdown@ run and the workspaces it leased released —
-- (so a segment that is running is not preempted, and the stop waits for it to return), finds out through the
-- fence whether that settlement was a failure, and then publishes the one last snapshot: @Stopped@ with the
-- intentions the stop discarded, or, if @shutdown@ raised and nothing failed before, the failure; a session
-- that had already failed keeps the failure as its status and is published nothing more. It lets the UI read
-- the receipts of the controls it asked for, closes the publication and retires both owners.
--
-- = Retirement
--
-- Retirement waits for each owner's worker to have /actually ended/ (its raw completion, which supervision's
-- latch of the other owner's failure neither shortens nor lengthens), in the caller's own masking state, so it
-- is interruptible and an interruption does not end it. A cancellation of the enclosing scope cancels the owners
-- instead of stopping them: both exit cancelled and their instances settle as discarded.
module Hetoimasia.Sample.LuaDomains.Domains
  ( -- * Configuration
    DomainsConfig (..)
  , defaultConfig
  , Extension (..)
  , Where (..)
  , tickDuration
    -- * The owners
  , Domains (..)
  , Started (..)
  , withDomains
  , retireDomains
  , Retirement (..)
  , OwnerEnd (..)
  , latestSnapshot
    -- * The driver
  , TickOutcome (..)
  , stepTick
  , stopSession
  , runSession
  , SessionReport (..)
  , DomainsDefect (..)
  , admitGameplayTask
    -- * What the session leaves
  , Evidence (..)
  , OwnerEvidence (..)
  , InstanceEvidence (..)
  , cleanupEvidence
  ) where

import Control.Concurrent.STM
  ( STM
  , atomically
  , modifyTVar'
  , readTVar
  , readTVarIO
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, forM_, join, unless, void, when)
import Data.ByteString (ByteString)
import Data.IORef (modifyIORef', readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Int (Int64)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (catMaybes, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( Publication (Published)
  , closeSnapshot
  , observedValue
  , publish
  , readSnapshot
  )
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), MonotonicSource, durationFromNanoseconds, monotonicSource)
import Hetoimasia.Foundation.Worker (awaitCompletion, pollCompletion)
import Hetoimasia.Runtime.Supervision
  ( Disposition (Required)
  , Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (WorkerLive, WorkerStopped)
  , awaitSupervised
  , checkRuntime
  , supervisedWorker
  )
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (..), defaultBounds, validateBounds)
import Hetoimasia.Sample.LuaDomains.Candidate (Candidate (..), beginCandidate, commit)
import Hetoimasia.Sample.LuaDomains.Intention (Dispositions (..), noDispositions)
import Hetoimasia.Sample.LuaDomains.Queue (closeQueue, drain, nextUnstarted, reserved, seal, settle)
import Hetoimasia.Sample.LuaDomains.Registration (gameplayNamespaces, sampleRegistration, uiNamespaces)
import Hetoimasia.Sample.LuaDomains.Scenario (scriptedInputs)
import Hetoimasia.Sample.LuaDomains.Scripts (facadeChunk, gameplayChunk, gameplayModule, gameplaySource, interfaceModule, interfaceSource)
import Hetoimasia.Sample.LuaDomains.Session
  ( Ended (..)
  , SessionState (..)
  , evidenceNow
  , failedNow
  , markEnded
  , markPublished
  , recordFailure
  , requestStopNow
  , stopRequestedNow
  )
import Hetoimasia.Sample.LuaDomains.Shared
  ( ScriptedInput
  , Shared (..)
  , SharedSetup (..)
  , UiNotes
  , Watched (..)
  , abandonReceipts
  , assignControl
  , captureView
  , newShared
  , publishInitial
  , publisherOf
  , readerOf
  )
import Hetoimasia.Sample.LuaDomains.Snapshot
  ( GameSnapshot (..)
  , SessionFailure (..)
  , SessionStatus (..)
  , failureMessageLimit
  )
import Hetoimasia.Sample.LuaDomains.Tally
  ( ControlCounts
  , Counts (..)
  , Workspaces
  , countDiscarded'
  , countInvalidated'
  , countSettled
  , settledTotal
  )
import Hetoimasia.Sample.LuaDomains.World (World (worldTick))
import Hetoimasia.Scripting.Lua.Instance
  ( ControlAdmission (AdmitLogically)
  , Execution (ExecIdle)
  , InstanceAdmission (..)
  , InstanceBounds (..)
  , InstanceConfig (..)
  , InstanceControl (InstanceStop)
  , InstanceError (..)
  , InstanceFailure (..)
  , InstanceId
  , InstanceKind (Periodic)
  , InstancePhase (Active, Initializing)
  , InstanceOutcome (..)
  , LeaseOutcome
  , InstanceRequest (..)
  , InstanceSettlement (..)
  , InstanceSnapshot (..)
  , InstanceTicket
  , Interval (ElapsedEvery, LogicalTicks)
  , HookStage (..)
  , Escalation (Isolate)
  , Termination
  , admitInstance
  , awaitInstance
  , defaultInstanceConfig
  , inspectInstance
  , pollInstance
  , requestInstanceControl
  )
import qualified Hetoimasia.Scripting.Lua.Instance as Instance (InstancePhase (Paused))
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Lifecycle
  ( GrantTarget (..)
  , GrantedOwner (GrantedEndpoint)
  , Permit (PermitControl, PermitInspect)
  , instanceIdValue
  , lifecycleGrant
  )
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryReason)
  , EntryPoint
  , ErrorValue (ErrorAbsent, ErrorMessage, ErrorOpaque)
  , FaultReason (ScriptFailed)
  , Library (..)
  , ModuleRef
  , ModuleSource (sourceIdentity)
  , VmConfig (..)
  , vmConfig
  )
import Hetoimasia.Scripting.Lua.Registration (CapabilityType, Namespace, Registration, namespaceName)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord))
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), ExitRecord, LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
  ( ExecutionDomain (GameplayDomain, InterfaceDomain)
  , GrantAnswer (GrantAccepted)
  , Quanta (Quanta)
  , Quantum (Quantum)
  , ScheduledEndpoint
  , ScheduledOutcome (..)
  , ScheduledOwner
  , ScheduledSettlement (..)
  , ScheduledSpec (..)
  , ScheduledStart (..)
  , SchedulerBounds (..)
  , ServiceClass (OrdinaryClass)
  , TaskAdmission (..)
  , TaskKind (OneShot)
  , TaskRequest (..)
  , TickWait (TicksCompleted)
  , admitScheduledTask
  , awaitTask
  , awaitTicksComplete
  , cancelScheduled
  , grantScheduledStep
  , pollTask
  , retireScheduled
  , scheduledEndpoint
  , scheduledExitRecord
  , scheduledSpec
  , scheduledStatus
  , scheduledSupervised
  , startScheduledOwner
  )
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend, systemTimerBackend)

-- | Where an extra namespace is exposed.
data Where = InUi | InGameplay | InBoth
  deriving (Eq, Show)

-- | A namespace beside the sample's own, which only a test configuration supplies, with the capability
-- types its bindings hand out.
data Extension = Extension
  { extensionNamespace ∷ !Namespace
  , extensionWhere ∷ !Where
  , extensionCapabilities ∷ ![CapabilityType]
  }

-- | What a session is created from. The clock and timer are the UI owner's: the executable uses
-- the real ones and an example drives the UI owner with an injected clock and a fake timer wake.
-- The two sources are the owners' behaviors, which a configuration may replace; the extensions
-- and the fields marked test-only are the only way a test reaches anything of its own, and the
-- production configuration leaves them empty.
data DomainsConfig = DomainsConfig
  { configBounds ∷ !Bounds
  , configSession ∷ !Word64
    -- ^ The session's identity.
  , configSeed ∷ !Word64
    -- ^ The seed of the gameplay session's random stream.
  , configTicks ∷ !(Maybe Word64)
    -- ^ The last tick of a finite session; 'Nothing' for one that is driven by hand.
  , configStopAfter ∷ !(Maybe Word64)
    -- ^ The tick after which 'runSession' stops the session, for a scenario that stops it.
  , configTickDuration ∷ !Duration
    -- ^ The logical duration of one gameplay tick.
  , configUiInterval ∷ !Duration
    -- ^ The UI behavior's elapsed cadence.
  , configUiClock ∷ !MonotonicSource
  , configUiTimer ∷ !TimerBackend
  , configInput ∷ ![ScriptedInput]
    -- ^ The fake input source's list.
  , configScenario ∷ !Text
    -- ^ The scenario's name, which the UI behavior reads.
  , configGameplaySource ∷ !ByteString
  , configUiSource ∷ !ByteString
  , configExtensions ∷ !(Shared → [Extension])
    -- ^ Test-only: namespaces beside the sample's own, made over the session's shared state.
  , configGameplayEntries ∷ ![EntryPoint]
    -- ^ Test-only: entry points the gameplay module declares beside its hooks, for the tasks a test admits.
  , configGameplayModules ∷ ![ModuleSource]
    -- ^ Test-only: modules the gameplay VM loads beside the behavior's, for the extra instances.
  , configGameplayInstances ∷ ![InstanceRequest]
    -- ^ Test-only: instances admitted to the gameplay owner after the behavior. Their failures fail the session.
  , configGameplaySpec ∷ !(ScheduledSpec → ScheduledSpec)
    -- ^ Test-only: the last word on the gameplay owner's configuration (a request service and subscriptions).
  , configAssignHook ∷ !(IO ())
    -- ^ Test-only: run by a control's assignment before it returns, in the interval before the engine admits it.
  , configPace ∷ !(Word64 → IO ())
    -- ^ Run after each committed tick of 'runSession'. It paces a session in real time and takes
    -- no part in what a tick contains.
  }

-- | The production configuration: the default bounds, session 1 at seed 1 for twenty ticks of ten
-- milliseconds, the UI updating every two milliseconds on the real clock and timer, the fixed
-- fake input, the sample's own scripts, the @normal@ scenario and nothing of a test's.
defaultConfig ∷ DomainsConfig
defaultConfig =
  DomainsConfig
    { configBounds = defaultBounds
    , configSession = 1
    , configSeed = 1
    , configTicks = Just 20
    , configStopAfter = Nothing
    , configTickDuration = tickDuration
    , configUiInterval = positive 2000000
    , configUiClock = monotonicSource
    , configUiTimer = systemTimerBackend
    , configInput = scriptedInputs
    , configScenario = "normal"
    , configGameplaySource = gameplaySource
    , configUiSource = interfaceSource
    , configExtensions = const []
    , configGameplayEntries = []
    , configGameplayModules = []
    , configGameplayInstances = []
    , configGameplaySpec = id
    , configAssignHook = pure ()
    , configPace = \_ → pure ()
    }

-- | Ten milliseconds of logical time per tick.
tickDuration ∷ Duration
tickDuration = positive 10000000

positive ∷ Integer → Duration
positive nanoseconds = either (error . ("the duration was refused: " <>) . show) id (durationFromNanoseconds RequirePositive nanoseconds)

-- | What goes wrong that is the sample's own and never a script's.
data DomainsDefect
  = -- | The configuration's bounds are refused.
    BoundsRefused ![String]
  | -- | An owner did not come up: the answer creation gave.
    OwnerDidNotStart !Text !String
  | -- | A behavior was not admitted, or ended without a failure the session could name.
    BehaviorDidNotStart !Text !String
  | -- | The driver was asked for a tick beyond a finite session's last.
    PastFinalTick !Word64
  | -- | The driver was asked for a tick while another had begun and not committed: a tick that
    -- did not complete leaves the session halted, and two drivers never share one.
    TickAlreadyInProgress !Word64
  | -- | The queue's next tick is not the committed tick plus one: the two numberings of ticks
    -- disagree. The tick asked for and the committed tick.
    TickOutOfSequence !Word64 !Word64
  | -- | A grant was not accepted: the answer.
    TickNotGranted !Word64 !String
  | -- | The gameplay owner ended while the tick was outstanding. The owner's own failure, if it
    -- failed, is supervision's to report: it is retained beside this one, or raised in its place if
    -- supervision delivers it to the driver first.
    OwnerEndedDuringTick !Word64
  | -- | The tick completed without its work having finished successfully and with no failure to
    -- name, so nothing was committed.
    TickNotCompleted !Word64
  | -- | A snapshot was refused because its publisher had closed.
    PublicationRefused !Word64
  | -- | The fence task was not admitted, or did not run to its end: what was answered.
    FenceFailed !String
  | -- | 'runSession' was asked to run a session that is not finite.
    SessionNotFinite
  | -- | A session ended with something pending, or with the ledger out of balance: the counters and
    -- what was pending.
    ConservationViolated !Counts !Int
  deriving (Eq, Show)

instance Exception DomainsDefect

-- | An owner and the one behavior instance it hosts.
data Started = Started
  { startedOwner ∷ !ScheduledOwner
  , startedInstance ∷ !InstanceId
  , startedTicket ∷ !InstanceTicket
  }

-- | A running session: the shared state and the two owners.
data Domains = Domains
  { domainsConfig ∷ !DomainsConfig
  , domainsShared ∷ !Shared
  , domainsControl ∷ !RuntimeControl
  , domainsGameplay ∷ !Started
  , domainsExtras ∷ ![Started]
    -- ^ A test's extra instances on the gameplay owner.
  , domainsUi ∷ !Started
  }

-- | How one owner ended.
data OwnerEnd = OwnerEnd
  { endExit ∷ !(Maybe ExitRecord)
    -- ^ The owner's exit record.
  , endInstance ∷ !(Maybe InstanceSettlement)
    -- ^ The settlement of its behavior instance.
  , endExtras ∷ ![InstanceSettlement]
    -- ^ The settlements of its other instances, if it had any.
  }
  deriving (Show)

-- | How both owners ended, UI first.
data Retirement = Retirement
  { retiredUi ∷ !OwnerEnd
  , retiredGameplay ∷ !OwnerEnd
  }
  deriving (Show)

-- | How a retirement ends the owners.
data How = Orderly | Cancelled
  deriving (Eq, Show)

-- Creation ---------------------------------------------------------------------------

-- | Run a body over a session: both owners created, ready, with their behaviors settled in their start (active,
-- or failed, which fails the session and is published), under this supervision boundary, and retired on every way out.
--
-- Retirement is not a release: it waits for each owner's worker to have /actually ended/ (its raw
-- completion, which supervision's latch of the other owner's failure neither shortens nor
-- lengthens), and a segment that is running is waited for, so it can take as long as that segment.
-- It therefore runs in the caller's own masking state, interruptibly, and an interruption does not
-- end it: each is recorded, the wait goes on until both owners have ended, and then what happened is
-- raised, a cancellation first, with the rest kept as cleanup evidence beside it. When the body ended by
-- a cancellation, the owners are cancelled, not stopped: they exit cancelled, and their instances settle as
-- discarded. When this returns or raises, from inside the supervision boundary, neither owner is live.
withDomains ∷ RuntimeControl → DomainsConfig → (Domains → IO a) → IO a
withDomains control config body = mask $ \restore → do
  domains ← startDomains restore control config
  outcome ← tryWithContext @SomeException (restore (body domains))
  let how = case outcome of
        Left (ExceptionWithContext _ failure) | isJust (fromException failure ∷ Maybe SomeAsyncException) → Cancelled
        _ → Orderly
  (_, interruptions) ← retireWith restore how domains
  case outcome of
    Right result → do
      raiseAll interruptions
      -- Both owners have ended; raise what supervision committed of either.
      restore (checkRuntime control)
      pure result
    Left primary →
      composeCleanup (Just primary) [("lua domains retirement", interruption) | interruption ← interruptions]
        >>= maybe (rethrowIO primary) rethrowIO

-- | Create both owners, gameplay first. An owner that fails to start leaves nothing behind (creation
-- returns or raises only once its worker has ended), and one that started when the second fails is
-- retired, protected, before the failure propagates.
startDomains ∷ (∀ x. IO x → IO x) → RuntimeControl → DomainsConfig → IO Domains
startDomains restore control config = do
  forM_ (NonEmpty.nonEmpty (validateBounds (configBounds config))) $ \problems →
    throwIO (BoundsRefused (map show (NonEmpty.toList problems)))
  lending ← newLending
  leases ← newLeases lending (boundWorkspaces (configBounds config))
  shared ←
    newShared
      SharedSetup
        { setupBounds = configBounds config
        , setupSession = configSession config
        , setupSeed = configSeed config
        , setupFinal = configTicks config
        , setupInput = configInput config
        , setupLending = lending
        , setupLeases = leases
        , setupAssignHook = configAssignHook config
        , setupScenario = configScenario config
        }
  runtime ← newLuaRuntime control
  let extensions = configExtensions config shared
  registered ←
    either
      (throwIO . OwnerDidNotStart "registration" . show)
      pure
      (sampleRegistration shared (concatMap extensionCapabilities extensions) (map extensionNamespace extensions))
  gameplayOwner ← startOwner runtime "gameplay" (gameplaySpec shared config registered)
  outcome ← tryWithContext @SomeException $ do
    gameplay ←
      admitBehavior
        gameplayOwner
        "gameplay"
        (sourceIdentity (gameplayModule (configGameplayEntries config) (configGameplaySource config)))
        (Periodic (LogicalTicks 1))
        []
    extras ←
      mapM
        (\request → admitBehavior gameplayOwner (maybe "extra" id (instanceName request)) (instanceModule request) (instanceKind request) (instanceGrants request))
        (configGameplayInstances config)
    -- A behavior that has left its init is serving, or has ended and told the session why; either way the
    -- UI starts, and sees the snapshot that says so.
    mapM_ (awaitStart control) (gameplay : extras)
    publishInitial shared (Just (tidOf (startedInstance gameplay)))
    uiOwner ← startOwner runtime "interface" (uiSpec shared config registered (scheduledEndpoint gameplayOwner))
    started ←
      tryWithContext @SomeException $ do
        ui ←
          admitBehavior
            uiOwner
            "interface"
            (sourceIdentity (interfaceModule (configUiSource config)))
            (Periodic (ElapsedEvery (configUiInterval config)))
            []
        awaitStart control ui
        pure ui
    case started of
      Left failure → rollback restore uiOwner failure
      Right ui → pure (Domains config shared control gameplay extras ui)
  case outcome of
    Left failure → rollback restore gameplayOwner failure
    Right domains → do
      -- A behavior that ended in its init has failed the session before the first tick: the failure is
      -- published beside the initial world, once, now that the UI can see it.
      settled ← tryWithContext @SomeException (settleStart domains)
      case settled of
        Left failure → do
          (_, interruptions) ← retireWith restore Orderly domains
          composeCleanup (Just failure) [("lua domains rollback", interruption) | interruption ← interruptions]
            >>= maybe (rethrowIO failure) rethrowIO
        Right () → pure domains

-- | The gameplay owner's configuration: the gameplay domain, its own libraries, bounds, initial
-- chunk and policy, admitting controls logically, leasing its instances' workspaces, and telling the
-- session of every failure of an instance.
gameplaySpec ∷ Shared → DomainsConfig → Registration → ScheduledSpec
gameplaySpec shared config registered =
  configGameplaySpec
    config
    ( (scheduledSpec vm (workerPolicy "gameplay") gameplayScheduling)
        { scheduledDomain = GameplayDomain
        , scheduledInstances = Just ((instanceConfigFor config) {instanceControlAdmission = AdmitLogically, instanceEscalate = gameplayEscalation shared})
        , scheduledLending = Just (sharedLending shared)
        , scheduledLeases = Just (sharedLeases shared)
        }
    )
  where
    vm =
      (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
        { vmInitialChunks = [gameplayChunk]
        , vmOwnerName = "gameplay"
        , vmRegistration = registered
        , vmPolicy = gameplayNamespaces <> extensionNames InGameplay shared config
        , vmModules = gameplayModule (configGameplayEntries config) (configGameplaySource config) : configGameplayModules config
        }

-- | The UI owner's configuration: the interface domain, its own libraries (the UI keeps
-- @math.random@), bounds, initial chunk (the facades) and policy, on the configured clock and timer,
-- capturing the latest snapshot as each segment is about to run, and granted control and inspection of the
-- gameplay owner and nothing else.
uiSpec ∷ Shared → DomainsConfig → Registration → ScheduledEndpoint → ScheduledSpec
uiSpec shared config registered gameplayEndpoint =
  (scheduledSpec vm (workerPolicy "interface") uiScheduling)
    { scheduledDomain = InterfaceDomain
    , scheduledClock = configUiClock config
    , scheduledTimer = configUiTimer config
    , scheduledObserve = \_ → captureView shared
    , scheduledInstances = Just ((instanceConfigFor config) {instanceEscalate = uiEscalation shared})
    , scheduledLifecycle =
        Just (lifecycleGrant [GrantTarget (GrantedEndpoint gameplayEndpoint) [PermitInspect, PermitControl] (Just (assignControl shared))])
    }
  where
    vm =
      (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
        { vmInitialChunks = [facadeChunk]
        , vmOwnerName = "interface"
        , vmRegistration = registered
        , vmPolicy = uiNamespaces <> extensionNames InUi shared config
        , vmModules = [interfaceModule (configUiSource config)]
        }

-- | The extension namespaces a policy exposes.
extensionNames ∷ Where → Shared → DomainsConfig → [Text]
extensionNames place shared config =
  [ namespaceName (extensionNamespace extension)
  | extension ← configExtensions config shared
  , extensionWhere extension == place || extensionWhere extension == InBoth
  ]

-- | Each owner hosts a few instances: the behavior, and a test's extras on the gameplay owner. The bounds
-- satisfy the scheduler's own requirements of them (retained results at least twice the live instances, and a
-- queue of admissions that holds each).
instanceConfigFor ∷ DomainsConfig → InstanceConfig
instanceConfigFor config =
  defaultInstanceConfig
    { instanceBounds = InstanceBounds {boundLiveInstances = 4, boundRetainedInstances = 8, boundInvocationQueue = 8, boundInstanceControls = 8}
    , instanceTickDuration = Just (configTickDuration config)
    }

-- | Gameplay's scheduling: four tasks, eight queued admissions and retained results, and one
-- grant outstanding at a time, which is enough (P-6).
gameplayScheduling ∷ SchedulerBounds
gameplayScheduling =
  SchedulerBounds
    { boundActiveTasks = 4
    , boundQueuedAdmissions = 8
    , boundRetainedResults = 8
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 1
    , boundControlRequests = 4
    , boundServiceBudget = Nothing
    }

-- | The UI's scheduling: its own bounds, of the same size. It is never granted a step.
uiScheduling ∷ SchedulerBounds
uiScheduling =
  SchedulerBounds
    { boundActiveTasks = 4
    , boundQueuedAdmissions = 8
    , boundRetainedResults = 8
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 1
    , boundControlRequests = 4
    , boundServiceBudget = Nothing
    }

-- | Both owners are services that run until asked to stop, and each is required: an owner that
-- fails ends the session.
workerPolicy ∷ Text → WorkerPolicy
workerPolicy label =
  WorkerPolicy Service Required (unsafeComponent ("sample.lua-domains." <> label)) (\_ → pure Unrecognized)

-- Escalation ----------------------------------------------------------------------

-- | What the gameplay owner tells the session of each failure of an instance, on its own thread, after the
-- instance has ended: a script failure fails the session, and the instance's peers go on (@Isolate@), so the
-- owner stays alive and quiescent. A failure that is only a failed release is cleanup evidence, fatal under
-- supervision, and is never a session failure.
gameplayEscalation ∷ Shared → InstanceFailure → IO Escalation
gameplayEscalation shared failure = do
  when (recordable failure) . atomically $ do
    tick ← currentTick shared
    recordFailure (sharedSession shared) (sessionFailureOf tick failure)
  pure Isolate

-- | Whether an instance's failure is a failure of script execution: not one whose primary is a failed release.
recordable ∷ InstanceFailure → Bool
recordable failure = case (failureStage failure, failureError failure) of
  (StageRelease, _) → False
  (_, ErrorRelease _) → False
  _ → True

-- | The tick a failure is told of at: the tick in progress, or the last committed one.
currentTick ∷ Shared → STM Word64
currentTick shared =
  readTVar (sharedTick shared) >>= \case
    Just working → pure (candidateTick working)
    Nothing → worldTick <$> readTVar (sharedCommitted shared)

-- | An instance's failure as the evidence names it.
sessionFailureOf ∷ Word64 → InstanceFailure → SessionFailure
sessionFailureOf tick failure =
  SessionFailure
    { failWho = maybe "instance" id (failureName failure)
    , failPhase = Text.toLower (Text.pack (show (failurePhase failure)))
    , failStage = stageText (failureStage failure)
    , failTick = tick
    , failKind = kindText (failureError failure)
    , failMessage = boundedMessage (messageOf failure)
    }

stageText ∷ HookStage → Text
stageText = \case
  StageInit → "init"
  StageRun → "run"
  StageUpdate → "update"
  StageEvent source → "event " <> source
  StageShutdown → "shutdown"
  StageRelease → "release"

kindText ∷ InstanceError → Text
kindText = \case
  ErrorFault (BoundaryFailed fault) | ScriptFailed _ _ ← boundaryReason fault → "script error"
  ErrorFault _ → "script fault"
  ErrorMissingEntry _ → "missing entry point"
  ErrorRefusedWait _ → "refused wait"
  ErrorRelease _ → "release failure"
  ErrorDelivery _ _ → "delivery failure"
  ErrorCadence _ → "cadence failure"

-- | What the instance's code said: the error it raised, when it raised one, and otherwise the engine's rendering.
messageOf ∷ InstanceFailure → Text
messageOf failure = case failureError failure of
  ErrorFault (BoundaryFailed fault) → case boundaryReason fault of
    ScriptFailed _ (ErrorMessage message _) → message
    ScriptFailed _ (ErrorOpaque kind) → "an error value of type " <> kind
    ScriptFailed _ ErrorAbsent → "no error value"
    other → Text.pack (show other)
  _ → failureMessage failure

-- | A message with its control characters replaced and cut to the evidence's bound.
boundedMessage ∷ Text → Text
boundedMessage = Text.take failureMessageLimit . Text.map (\c → if c < ' ' || c == '\DEL' then ' ' else c)

-- | What the UI owner tells the session of a failure of its behavior: it is recorded, once and bounded, the
-- instance ends, and nothing else changes: gameplay is not told, and the behavior is not restarted. What
-- receipts it held are abandoned with it.
uiEscalation ∷ Shared → InstanceFailure → IO Escalation
uiEscalation shared failure = do
  atomically $ do
    tick ← currentTick shared
    held ← readTVar (sharedUiFailure shared)
    when (held == Nothing) (writeTVar (sharedUiFailure shared) (Just (sessionFailureOf tick failure)))
  void (abandonReceipts shared)
  pure Isolate

-- Starting ------------------------------------------------------------------------

startOwner ∷ LuaRuntime → Text → ScheduledSpec → IO ScheduledOwner
startOwner runtime name spec =
  startScheduledOwner runtime spec >>= \case
    ScheduledStarted owner → pure owner
    ScheduledUnavailable failure → throwIO (OwnerDidNotStart name (show failure))
    ScheduledRejected → throwIO (OwnerDidNotStart name "the supervision boundary had closed")
    ScheduledEnded → throwIO (OwnerDidNotStart name "the owner ended before it was ready")

-- | Admit an owner's behavior. It is not awaited: an instance whose init fails has ended, and is a failure
-- of the session, not of the start.
admitBehavior ∷ ScheduledOwner → Text → ModuleRef → InstanceKind → [Text] → IO Started
admitBehavior owner name ref kind grants = do
  admission ← admitInstance (scheduledEndpoint owner) (InstanceRequest ref kind (Just name) OrdinaryClass grants)
  case admission of
    InstanceAccepted identity ticket → pure (Started owner identity ticket)
    other → throwIO (BehaviorDidNotStart name (show other))

-- | Wait, supervised, until the instance has left its initialization: it is active, or it has ended.
awaitStart ∷ RuntimeControl → Started → IO ()
awaitStart control started =
  awaitSupervised control $
    inspectInstance (scheduledEndpoint (startedOwner started)) (startedInstance started) >>= \case
      Just snapshot | snapshotPhase snapshot /= Initializing → pure ()
      _ → retry

-- | Retire an owner that came up when the rest of construction failed, and raise the failure, with
-- whatever interrupted the wait kept beside it.
rollback ∷ (∀ x. IO x → IO x) → ScheduledOwner → ExceptionWithContext SomeException → IO a
rollback restore owner failure = do
  interruptions ← stopOwner restore Orderly owner
  composeCleanup (Just failure) [("lua domains rollback", interruption) | interruption ← interruptions]
    >>= maybe (rethrowIO failure) rethrowIO

-- | An instance's identity as a script holds it: the runtime, the owner and the number.
tidOf ∷ InstanceId → (Int64, Int64, Int64)
tidOf identity = case instanceIdValue identity of
  VRecord [("runtime", VInteger runtime), ("owner", VInteger owner), ("id", VInteger number)] → (runtime, owner, number)
  _ → (0, 0, 0)

-- Waiting and stopping -----------------------------------------------------------------

-- | Ask an owner to stop, or cancel it, and wait until its worker has actually ended: its raw completion,
-- which the supervision latch neither shortens nor lengthens. The wait runs in the caller's state, so it is
-- interruptible; an interruption is recorded and the wait goes on, until the worker has ended. It answers the
-- interruptions, in the order they arrived.
stopOwner ∷ (∀ x. IO x → IO x) → How → ScheduledOwner → IO [ExceptionWithContext SomeException]
stopOwner restore how owner = do
  case how of
    Orderly → retireScheduled owner
    Cancelled → cancelScheduled owner
  go []
  where
    go interruptions =
      tryWithContext @SomeException (restore (atomically (void (awaitCompletion (supervisedWorker (scheduledSupervised owner)))))) >>= \case
        Right () → pure (reverse interruptions)
        Left interruption → go (interruption : interruptions)

-- | Raise what went wrong, in the order it happened: a cancellation, if one was among them, is the
-- one that propagates, as itself; otherwise the first is, and every other is kept whole as cleanup
-- evidence beside it. Nothing to raise returns.
raiseAll ∷ [ExceptionWithContext SomeException] → IO ()
raiseAll failures = case lookup chosen indexed of
  Nothing → pure ()
  Just primary →
    composeCleanup (Just primary) [("lua domains retirement", failure) | (index, failure) ← indexed, index /= chosen]
      >>= maybe (rethrowIO primary) rethrowIO
  where
    indexed = zip [0 ∷ Int ..] failures
    isCancellation (ExceptionWithContext _ exception) = isJust (fromException exception ∷ Maybe SomeAsyncException)
    chosen = case [index | (index, failure) ← indexed, isCancellation failure] of
      index : _ → index
      [] → 0

-- | Retire both owners in order and say how each ended, and what interrupted the waiting. Admission ends
-- first, as an owner's does when it stops: nothing is accepted for a tick that will never run, and what no
-- commit settled is counted as discarded, so the ledger balances on every path. The UI owner is retired and
-- awaited next, being the producer of intentions and the reader of snapshots, and the receipts it held are
-- then abandoned, reported apart; then gameplay, and only then does the snapshot's publication end. Every
-- step is idempotent, so retiring again changes nothing.
retireWith ∷ (∀ x. IO x → IO x) → How → Domains → IO (Retirement, [ExceptionWithContext SomeException])
retireWith restore how domains = do
  let shared = domainsShared domains
  atomically $ do
    closeQueue (sharedQueue shared)
    left ← drain (sharedQueue shared)
    unless (null left) (modifyTVar' (sharedCounts shared) (countDiscarded' (length left)))
  uiInterruptions ← stopOwner restore how (startedOwner (domainsUi domains))
  void (abandonReceipts shared)
  gameplayInterruptions ← stopOwner restore how (startedOwner (domainsGameplay domains))
  atomically $
    readTVar (sharedPublication shared) >>= \case
      Nothing → pure ()
      Just publisher → closeSnapshot publisher
  atomically (writeTVar (sharedClosed shared) True)
  ui ← endOf [domainsUi domains]
  gameplay ← endOf (domainsGameplay domains : domainsExtras domains)
  pure (Retirement ui gameplay, uiInterruptions <> gameplayInterruptions)
  where
    endOf started = do
      record ← atomically (scheduledExitRecord (maybe (startedOwner (domainsUi domains)) startedOwner (listToMaybe started)))
      settlements ← mapM (pollInstance . startedTicket) started
      pure (OwnerEnd record (join (listToMaybe settlements)) (catMaybes (drop 1 settlements)))

-- | Retire both owners, the UI first, and say how each ended. Waiting for an owner that holds a
-- segment waits for the segment to return, as the owners' stop does (nothing is preempted). It can be
-- called again, and after the owners have ended it answers at once.
retireDomains ∷ Domains → IO Retirement
retireDomains domains = do
  (retirement, interruptions) ← retireWith id Orderly domains
  raiseAll interruptions
  pure retirement

-- | The latest committed snapshot, read as a UI segment's capture reads it.
latestSnapshot ∷ Domains → IO GameSnapshot
latestSnapshot domains = atomically $ do
  reader ← readerOf (domainsShared domains)
  preparedValue . observedValue <$> readSnapshot reader

-- The fence and the tasks ---------------------------------------------------------

-- | The behavior's instance, as the engine reports it now.
behaviorNow ∷ Started → STM (Maybe InstanceSnapshot)
behaviorNow started = inspectInstance (scheduledEndpoint (startedOwner started)) (startedInstance started)

-- | The module the fence task's entry point is in.
fenceModule ∷ ModuleRef
fenceModule = sourceIdentity (gameplayModule [] "")

-- | Admit the fence task and wait for its settlement. The owner runs a segment and then the boundary after
-- it, one after the other, so the fence's segment begins only once every boundary before it is over: what the
-- instance layer was to account for, it has, an instance that failed has ended and the application has been
-- told. What the fence settles as other than returned is a defect of the sample.
fence ∷ Domains → IO ()
fence domains = do
  admission ← admitScheduledTask (scheduledEndpoint (startedOwner (domainsGameplay domains))) (TaskRequest fenceModule "sample_fence" [] OrdinaryClass OneShot (Just "fence"))
  case admission of
    TaskAccepted _ ticket → do
      settlement ← awaitTask (domainsControl domains) ticket
      case settledOutcome settlement of
        SettledReturned _ → pure ()
        other → throwIO (FenceFailed (take 200 (show other)))
    other → throwIO (FenceFailed (show other))

-- | Admit a task to the gameplay owner as the session's: if it faults, the session fails, as an instance's
-- failure fails it.
admitGameplayTask ∷ Domains → TaskRequest → IO TaskAdmission
admitGameplayTask domains request = do
  admission ← admitScheduledTask (scheduledEndpoint (startedOwner (domainsGameplay domains))) request
  case admission of
    TaskAccepted _ ticket →
      modifyIORef' (sharedTasks (domainsShared domains)) (<> [Watched (maybe "task" id (requestName request)) ticket])
    _ → pure ()
  pure admission

-- | Read the settlement of each task the session admitted that has one, and record a fault as a session failure.
-- Each task is read once.
watchTasks ∷ Domains → IO ()
watchTasks domains = do
  let shared = domainsShared domains
  held ← readIORef (sharedTasks shared)
  remaining ← forM held $ \watched →
    pollTask (watchedTicket watched) >>= \case
      Nothing → pure (Just watched)
      Just settlement → do
        forM_ (faultOf (settledOutcome settlement)) $ \(kind, message) →
          atomically $ do
            tick ← currentTick shared
            recordFailure (sharedSession shared) (SessionFailure (watchedName watched) "task" "task" tick kind (boundedMessage message))
        pure Nothing
  writeIORef (sharedTasks shared) (catMaybes remaining)
  where
    faultOf = \case
      SettledFaulted fault → Just ("script fault", Text.pack (take 600 (show fault)))
      SettledRefused why → Just ("refused wait", Text.pack (take 600 (show why)))
      _ → Nothing

-- The driver ------------------------------------------------------------------------

-- | What one step of the driver came to.
data TickOutcome
  = -- | The tick was committed, and this is its snapshot.
    TickCommitted !GameSnapshot
  | -- | The session failed: nothing was committed, and this is the failure's snapshot, published now.
    TickFailed !GameSnapshot
  | -- | The session is no longer running a tick (it failed, was stopped, or ended): nothing began.
    TickHalted
  deriving (Show)

-- | Whether the session takes no more ticks: a failure was told of, a stop was asked for, or it ended.
haltedNow ∷ Shared → STM Bool
haltedNow shared = do
  failed ← failedNow (sharedSession shared)
  stopping ← stopRequestedNow (sharedSession shared)
  state ← readTVar (sharedSession shared)
  pure (failed || stopping || isJust (sessionEnded state))

-- | Whether the UI behavior is serving: only then is a control request it may be making waited for.
uiServing ∷ Domains → STM Bool
uiServing domains = maybe False ((== Active) . snapshotPhase) <$> behaviorNow (domainsUi domains)

-- | Run one gameplay tick as the module header describes.
stepTick ∷ Domains → IO TickOutcome
stepTick domains = do
  let shared = domainsShared domains
      config = domainsConfig domains
      gameplay = domainsGameplay domains
      owner = startedOwner gameplay
  pending ← atomically $ do
    failed ← failedNow (sharedSession shared)
    state ← readTVar (sharedSession shared)
    pure (failed && sessionEnded state == Nothing)
  if pending
    then maybe TickHalted TickFailed <$> settleFailure domains
    else do
      begun ← atomically $ do
        halted ← haltedNow shared
        if halted
          then pure Nothing
          else do
            -- A control request between the assignment of its place and the engine's admission of it is
            -- waited for, unless the UI that made it has ended: the engine never finds its tick begun.
            requesting ← readTVar (sharedControlsInFlight shared)
            serving ← uiServing domains
            when (requesting > 0 && serving) retry
            next ← nextUnstarted (sharedQueue shared)
            when (maybe False (next >) (configTicks config)) $ throwSTM (PastFinalTick next)
            inProgress ← readTVar (sharedTick shared)
            forM_ inProgress $ \working → throwSTM (TickAlreadyInProgress (candidateTick working))
            committed ← readTVar (sharedCommitted shared)
            -- The queue's ticks and the world's are one numbering; a disagreement is a defect, found before
            -- anything is sealed (a throw abandons the whole transaction).
            when (worldTick committed + 1 /= next) $ throwSTM (TickOutOfSequence next (worldTick committed))
            (tick, sealed) ← seal (sharedQueue shared)
            writeTVar (sharedTick shared) (Just (beginCandidate (configBounds config) committed tick sealed))
            paused ← maybe False ((== Instance.Paused) . snapshotPhase) <$> behaviorNow gameplay
            pure (Just (tick, paused))
      case begun of
        Nothing → pure TickHalted
        Just (tick, pausedAtBegin) → do
          granted ← grantScheduledStep (scheduledEndpoint owner) (configTickDuration config)
          case granted of
            GrantAccepted _ → pure ()
            other → throwIO (TickNotGranted tick (show other))
          waited ← awaitTicksComplete (domainsControl domains) owner
          unless (waited == TicksCompleted) $ throwIO (OwnerEndedDuringTick tick)
          fence domains
          watchTasks domains
          decide domains tick pausedAtBegin

-- | What the driver decided after the fence.
data Verdict
  = VerdictFailed
  | VerdictHalted
  | VerdictIncomplete
  | VerdictCommit !Candidate

-- | Decide a tick that has completed and been fenced: a failure told of fails the session and commits
-- nothing; a stop commits nothing; otherwise the tick commits if its work finished successfully, or the engine says why
-- there is none to do.
decide ∷ Domains → Word64 → Bool → IO TickOutcome
decide domains tick pausedAtBegin = do
  let shared = domainsShared domains
  verdict ← atomically $ do
    halted ← haltedNow shared
    failed ← failedNow (sharedSession shared)
    if failed
      then pure VerdictFailed
      else
        if halted
          then pure VerdictHalted
          else do
            working ← readTVar (sharedTick shared)
            instanceNow ← behaviorNow (domainsGameplay domains)
            assigned ← Set.member tick <$> readTVar (sharedControlTicks shared)
            pure $ case (working, instanceNow) of
              (Just candidate, Just snapshot)
                | candidateTick candidate == tick
                , acceptable candidate snapshot assigned → VerdictCommit candidate
              _ → VerdictIncomplete
  case verdict of
    VerdictFailed → maybe TickHalted TickFailed <$> publishEnding domains EndedByFailure
    VerdictHalted → pure TickHalted
    VerdictIncomplete → throwIO (TickNotCompleted tick)
    VerdictCommit candidate → commitTick domains tick candidate
  where
    -- Work finished successfully: gameplay said so, and the instance is serving, with nothing in flight and
    -- no update owed; or there was no work to do and the engine says why: the behavior is paused, was paused
    -- as the tick began, or a control was applied at its boundary. A paused instance may hold an update it
    -- will not run.
    acceptable candidate snapshot assigned =
      snapshotExecution snapshot == ExecIdle
        && case snapshotPhase snapshot of
          Active → not (snapshotUpdateOwed snapshot) && (candidateFinished candidate || pausedAtBegin || assigned)
          Instance.Paused → True
          _ → False

-- | Commit a tick: replace the committed world, publish the snapshot, settle the queue's reservations and count
-- the dispositions, in one transaction that first checks again that nothing has ended the session meanwhile.
commitTick ∷ Domains → Word64 → Candidate → IO TickOutcome
commitTick domains tick candidate = do
  let shared = domainsShared domains
      config = domainsConfig domains
      (world, dispositions) = commit candidate
  identity ← snapGameplay <$> readTVarIO (sharedView shared)
  built ← atomically $ do
    halted ← haltedNow shared
    failed ← failedNow (sharedSession shared)
    working ← readTVar (sharedTick shared)
    instanceNow ← behaviorNow (domainsGameplay domains)
    pure $
      if failed
        then Left True
        else
          if halted || fmap candidateTick working /= Just tick
            then Left False
            else
              Right
                GameSnapshot
                  { snapSession = configSession config
                  , snapTick = tick
                  , snapWorld = world
                  , snapDispositions = dispositions
                  , snapStatus = if fmap snapshotPhase instanceNow == Just Instance.Paused then Paused else Running
                  , snapGameplay = identity
                  }
  case built of
    Left True → maybe TickHalted TickFailed <$> publishEnding domains EndedByFailure
    Left False → pure TickHalted
    Right snapshot → do
      prepared ← prepare snapshot
      done ← atomically $ do
        halted ← haltedNow shared
        failed ← failedNow (sharedSession shared)
        working ← readTVar (sharedTick shared)
        if halted || failed || fmap candidateTick working /= Just tick
          then pure (Left failed)
          else do
            writeTVar (sharedCommitted shared) world
            writeTVar (sharedTick shared) Nothing
            settle (sharedQueue shared) tick
            modifyTVar' (sharedCounts shared) (countSettled (length (dispApplied dispositions)) (length (dispStale dispositions) + dispStaleOmitted dispositions))
            publisher ← publisherOf shared
            publish publisher prepared >>= \case
              Published → pure (Right ())
              _ → throwSTM (PublicationRefused tick)
      case done of
        Right () → pure (TickCommitted snapshot)
        Left True → maybe TickHalted TickFailed <$> publishEnding domains EndedByFailure
        Left False → pure TickHalted

-- | Tell the session's failure after a fence, and publish it.
settleFailure ∷ Domains → IO (Maybe GameSnapshot)
settleFailure domains = do
  fence domains
  watchTasks domains
  publishEnding domains EndedByFailure

-- | How a session's last publication ends it.
data Ending = EndedByFailure | EndedByStop

-- | Publish the one snapshot that ends a session, once: the last good world and committed tick beside the
-- failure and what it invalidated, or beside @Stopped@ and what the stop discarded. Admission is closed, the
-- candidate discarded, and what no commit settled drained, in the transaction that decides to publish; a
-- session that has ended publishes nothing more, whatever asks.
publishEnding ∷ Domains → Ending → IO (Maybe GameSnapshot)
publishEnding domains ending = mask_ $ do
  let shared = domainsShared domains
      config = domainsConfig domains
      bounds = configBounds config
  built ← atomically $ do
    state ← readTVar (sharedSession shared)
    evidence ← evidenceNow (sharedSession shared)
    case (sessionEnded state, ending, evidence) of
      (Just _, _, _) → pure Nothing
      (Nothing, EndedByFailure, Nothing) → pure Nothing
      (Nothing, _, _) → do
        committed ← readTVar (sharedCommitted shared)
        dropped ← drain (sharedQueue shared)
        closeQueue (sharedQueue shared)
        writeTVar (sharedTick shared) Nothing
        identity ← snapGameplay <$> readTVar (sharedView shared)
        let places = map fst dropped
            listed = take (boundDroppedListed bounds) places
            omitted = max 0 (length places - boundDroppedListed bounds)
        (dispositions, status) ← case (ending, evidence) of
          (EndedByFailure, Just found) → do
            modifyTVar' (sharedCounts shared) (countInvalidated' (length places))
            markPublished (sharedSession shared) found
            pure (noDispositions {dispInvalidated = listed, dispInvalidatedOmitted = omitted}, Failed found)
          _ → do
            modifyTVar' (sharedCounts shared) (countDiscarded' (length places))
            markEnded (sharedSession shared) EndedStopped
            pure (noDispositions {dispDiscarded = listed, dispDiscardedOmitted = omitted}, Stopped)
        pure (Just (GameSnapshot (configSession config) (worldTick committed) committed dispositions status identity))
  forM built $ \snapshot → do
    prepared ← prepare snapshot
    atomically $ do
      publisher ← publisherOf shared
      publish publisher prepared >>= \case
        Published → pure ()
        _ → throwSTM (PublicationRefused (snapTick snapshot))
    pure snapshot

-- | After a start in which a behavior ended in its init: that is a failure of the session before its first tick,
-- published beside the initial world; a behavior that is neither serving nor failed is a defect of the sample.
settleStart ∷ Domains → IO ()
settleStart domains = do
  let behaviors = domainsGameplay domains : domainsExtras domains
  phases ← atomically (mapM (fmap (fmap snapshotPhase) . behaviorNow) behaviors)
  let unsettled = [phase | Just phase ← phases, phase /= Active]
  unless (null unsettled) $ do
    fence domains
    watchTasks domains
  failed ← atomically (failedNow (sharedSession (domainsShared domains)))
  if failed
    then void (publishEnding domains EndedByFailure)
    else unless (null unsettled) $ throwIO (BehaviorDidNotStart "gameplay" (show unsettled))

-- | The one stop of the session, from the driver, as the module header describes. It can be called again, and
-- from a thread that is not the driver's: it waits for the gameplay behavior to be settled, which waits for a
-- segment that is running to return. It answers how both owners ended. Once the owners are retired it only says how they ended again.
stopSession ∷ Domains → IO Retirement
stopSession domains = do
  let shared = domainsShared domains
  retired ← readTVarIO (sharedClosed shared)
  if retired then retireDomains domains else stopLive domains

-- | A stop of a session whose owners have not been retired.
stopLive ∷ Domains → IO Retirement
stopLive domains = do
  let shared = domainsShared domains
  atomically $ do
    void (requestStopNow (sharedSession shared))
    closeQueue (sharedQueue shared)
  forM_ (domainsGameplay domains : domainsExtras domains) $ \started → do
    void (requestInstanceControl (scheduledEndpoint (startedOwner started)) (startedInstance started) InstanceStop)
    void (awaitInstance (domainsControl domains) (startedTicket started))
  fence domains
  watchTasks domains
  failed ← atomically (failedNow (sharedSession shared))
  void (publishEnding domains (if failed then EndedByFailure else EndedByStop))
  -- The UI reads the settlements of the controls it asked for while it lives; a UI that has ended abandoned its receipts.
  awaitSupervised (domainsControl domains) $ do
    held ← readTVar (sharedReceipts shared)
    serving ← uiServing domains
    when (held > 0 && serving) retry
  retireDomains domains

-- | What a finite session did.
data SessionReport = SessionReport
  { reportSession ∷ !Word64
  , reportSeed ∷ !Word64
  , reportScenario ∷ !Text
  , reportTicks ∷ !Word64
    -- ^ The ticks committed.
  , reportStatus ∷ !SessionStatus
    -- ^ How the session ended: the status of the last publication.
  , reportCounts ∷ !Counts
  , reportControls ∷ !ControlCounts
  , reportUiUpdates ∷ !Int
  , reportUiNotes ∷ !UiNotes
  , reportUiFailure ∷ !(Maybe SessionFailure)
  , reportRetirement ∷ !Retirement
  , reportEvidence ∷ !Evidence
  }
  deriving (Show)

-- | Run a finite session: commit its ticks, pacing as the configuration says, until it ends: its last tick, a
-- failure, or the stop the scenario asks for after a tick; then settle it (a stop, for the two that did not run
-- to their end), retire both owners and read the counters and the evidence.
--
-- A session conserves its intentions: the queue closed to ticks beyond the last, every accepted intention is
-- exactly one of applied, rejected as stale, invalidated by the failure or discarded by the stop, so with the
-- producers gone nothing is pending and accepted equals their sum. If it does not, that is a defect of the sample
-- and 'ConservationViolated' is raised.
runSession ∷ Domains → IO SessionReport
runSession domains = do
  let config = domainsConfig domains
      shared = domainsShared domains
  total ← maybe (throwIO SessionNotFinite) pure (configTicks config)
  let go tick
        | tick > total = pure False
        | otherwise =
            stepTick domains >>= \case
              TickCommitted _ → do
                configPace config tick
                if configStopAfter config == Just tick then pure True else go (tick + 1)
              TickFailed _ → pure True
              TickHalted → pure True
  stoppedEarly ← go 1
  retirement ← if stoppedEarly then stopSession domains else retireDomains domains
  -- Both owners have ended: what supervision committed of either is raised, and the statuses the evidence reads are its decisions.
  checkRuntime (domainsControl domains)
  evidence ← cleanupEvidence domains
  (counts, left, controls, updates, notes, uiFailure, final) ← atomically $ do
    counts ← readTVar (sharedCounts shared)
    left ← reserved (sharedQueue shared)
    controls ← readTVar (sharedControls shared)
    updates ← readTVar (sharedUpdates shared)
    notes ← readTVar (sharedUiNotes shared)
    uiFailure ← readTVar (sharedUiFailure shared)
    reader ← readerOf shared
    snapshot ← preparedValue . observedValue <$> readSnapshot reader
    pure (counts, left, controls, updates, notes, uiFailure, snapshot)
  when (left /= 0 || countAccepted counts /= settledTotal counts) $
    throwIO (ConservationViolated counts left)
  pure (SessionReport (configSession config) (configSeed config) (configScenario config) (snapTick final) (snapStatus final) counts controls updates notes uiFailure retirement evidence)

-- Evidence ----------------------------------------------------------------------------

-- | One instance's end, as its settlement says.
data InstanceEvidence = InstanceEvidence
  { evidenceInstance ∷ !Text
  , evidenceOutcome ∷ !Text
    -- ^ completed, stopped, failed or discarded.
  , evidenceTermination ∷ !Termination
    -- ^ What its end revoked and discarded, and what became of @shutdown@.
  , evidenceLeases ∷ !LeaseOutcome
    -- ^ What its end did with the leases it held: released, awaited, and failed.
  }
  deriving (Show)

-- | One owner's end.
data OwnerEvidence = OwnerEvidence
  { evidenceEnded ∷ !Bool
    -- ^ Its worker has ended: its raw completion exists.
  , evidenceStatus ∷ !Text
    -- ^ What supervision has decided of it.
  , evidenceExit ∷ !(Maybe ExitRecord)
  , evidenceInstances ∷ ![InstanceEvidence]
  }
  deriving (Show)

-- | The one bounded record of how a session ended, for every way it can: both owners' exit records and
-- statuses and each instance's termination, the workspaces acquired against released (and attempted and failed),
-- whether the snapshot's publication ended, the intention ledger and what was left pending, the UI's control
-- requests (the receipts it abandoned reported apart), and the failures told of after the failure snapshot was published.
data Evidence = Evidence
  { evidenceUi ∷ !OwnerEvidence
  , evidenceGameplay ∷ !OwnerEvidence
  , evidenceWorkspaces ∷ !Workspaces
  , evidencePublicationClosed ∷ !Bool
  , evidenceLedger ∷ !Counts
  , evidencePending ∷ !Int
  , evidenceControls ∷ !ControlCounts
  , evidenceFailures ∷ !Int
    -- ^ Every session failure told of.
  , evidenceAfter ∷ ![SessionFailure]
    -- ^ The ones told of after the failure snapshot was published, bounded: never republished.
  }
  deriving (Show)

-- | Read the evidence of how the session has ended. It reads what retirement left, and answers whatever way the
-- session ended; read before retirement it says the owners have not ended.
cleanupEvidence ∷ Domains → IO Evidence
cleanupEvidence domains = do
  let shared = domainsShared domains
  ui ← ownerEvidence [domainsUi domains]
  gameplay ← ownerEvidence (domainsGameplay domains : domainsExtras domains)
  atomically $ do
    workspaces ← readTVar (sharedWorkspaces shared)
    closed ← readTVar (sharedClosed shared)
    counts ← readTVar (sharedCounts shared)
    left ← reserved (sharedQueue shared)
    controls ← readTVar (sharedControls shared)
    state ← readTVar (sharedSession shared)
    pure (Evidence ui gameplay workspaces closed counts left controls (sessionFailureCount state) (sessionAfter state))

ownerEvidence ∷ [Started] → IO OwnerEvidence
ownerEvidence started = case listToMaybe started of
  Nothing → pure (OwnerEvidence False "none" Nothing [])
  Just first → do
    let owner = startedOwner first
    ended ← isJust <$> atomically (pollCompletion (supervisedWorker (scheduledSupervised owner)))
    status ← atomically (scheduledStatus owner)
    record ← atomically (scheduledExitRecord owner)
    settlements ← mapM (pollInstance . startedTicket) started
    pure (OwnerEvidence ended (statusText status) record (map instanceEvidence (catMaybes settlements)))
  where
    statusText = \case
      WorkerLive → "live"
      WorkerStopped → "stopped"
      _ → "other"
    instanceEvidence settlement =
      InstanceEvidence
        { evidenceInstance = maybe "instance" id (resultName settlement)
        , evidenceOutcome = outcomeText (resultOutcome settlement)
        , evidenceTermination = terminationOf settlement
        , evidenceLeases = resultLeases settlement
        }
    outcomeText = \case
      InstanceCompleted → "completed"
      InstanceStopped → "stopped"
      InstanceFailed _ → "failed"
      InstanceDiscarded _ → "discarded"
    terminationOf = resultTermination
