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
-- 4. /Accounting/. Completion of the tick says only that the grant was applied and nothing is left that
--    it could run: the scheduler reconciles the grant before the instance layer has accounted for what the
--    tick's last segment did, so an invocation that the scheduler ended with a refused wait still looks,
--    for a moment, like an instance that is active with nothing in flight. The driver therefore waits for the
--    owner's accounting ('awaitScheduledAccounting', D-47), which takes no task, ticket or slot: an instance
--    that failed has ended — its @shutdown@ and the release of what it held included — and the application's
--    escalation has been called and has returned. Only then does the driver decide, and it never decides
--    from the tick's completion alone. An owner that ended instead has accounted for nothing, and nothing is
--    committed.
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
-- answers 'Isolate', and the fault of a task the session admitted is found by the driver after the accounting wait. From
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
-- accounting wait whether that settlement was a failure, and then publishes the one last snapshot: @Stopped@ with the
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
  , PublishPoint (..)
  , StopPoint (..)
  , TickPoint (..)
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
  , requestStop
  , stopSession
  , runSession
  , SessionReport (..)
  , ReplayOutcome (..)
  , Feed
  , DomainsDefect (..)
  , admitGameplayTask
  , tellTask
    -- * What the session leaves
  , Evidence (..)
  , OwnerEvidence (..)
  , InstanceEvidence (..)
  , cleanupEvidence
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, myThreadId)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
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
  , evaluate
  , finally
  , fromException
  , mask
  , mask_
  , onException
  , rethrowIO
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (foldM_, forM, forM_, join, unless, void, when)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Int (Int64)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, listToMaybe)
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
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (..), defaultBounds, maxSessionTicks, validateBounds)
import Hetoimasia.Sample.LuaDomains.Candidate (Candidate (..), beginCandidate, commit)
import Hetoimasia.Sample.LuaDomains.Canonical (Digest, digestSnapshot)
import Hetoimasia.Sample.LuaDomains.InputLog
  ( ControlOp (..)
  , InputLog
  , RecordProblem
  , Record (..)
  , appendRecord
  , byTick
  , checkReplayable
  , intentionOf
  , logRecords
  , maxRecords
  , recorderLog
  , ReplayProblem
  )
import Hetoimasia.Sample.LuaDomains.Intention (Dispositions (..), noDispositions)
import Hetoimasia.Sample.LuaDomains.Queue (AdmitAt (..), closeQueue, drain, isClosed, nextUnstarted, reserved, seal, settle)
import Hetoimasia.Sample.LuaDomains.Registration (gameplayNamespaces, sampleRegistration, uiNamespaces)
import Hetoimasia.Sample.LuaDomains.Scenario (scriptedInputs)
import Hetoimasia.Sample.LuaDomains.Scripts (facadeChunk, gameplayChunk, gameplayModule, gameplaySource, interfaceModule, interfaceSource)
import Hetoimasia.Sample.LuaDomains.Session
  ( Ended (..)
  , SessionState (..)
  , claimEnding
  , evidenceNow
  , failedNow
  , markEnded
  , markPublished
  , requestStopNow
  , stopRequestedNow
  )
import Hetoimasia.Sample.LuaDomains.Shared
  ( ScriptedInput
  , TaskEntry (..)
  , Shared (..)
  , SharedSetup (..)
  , UiNotes (..)
  , Watched (..)
  , abandonReceipts
  , admitLogged
  , appendTrace
  , assignControl
  , captureView
  , enterTaskAdmission
  , failSession
  , handOffTask
  , instanceTriple
  , leaveTaskAdmission
  , newShared
  , publishInitial
  , publisherOf
  , readerOf
  , supervisedWait
  , takesTasks
  , taskAdmissionsDrained
  )
import Hetoimasia.Sample.LuaDomains.Snapshot
  ( GameSnapshot (..)
  , SessionFailure (..)
  , SessionStatus (..)
  , failureMessageLimit
  )
import Hetoimasia.Sample.LuaDomains.Tally
  ( ControlCounts (controlAbandoned)
  , Counts (..)
  , Workspaces
  , bumpAnswer
  , bumpOffered
  , bumpSettled
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
  , ControlSlot (ControlSlot)
  , InstanceControl (InstancePause, InstanceResume, InstanceStop)
  , InstanceControlAnswer (..)
  , InstanceControlReceipt
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
  , pollInstanceControl
  , requestInstanceControl
  , requestInstanceControlAt
  )
import qualified Hetoimasia.Scripting.Lua.Instance as Instance (InstancePhase (Paused))
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Lifecycle
  ( GrantTarget (..)
  , GrantedOwner (GrantedEndpoint)
  , Permit (PermitControl, PermitInspect)
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
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), ExitRecord, LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
  ( AccountingWait (..)
  , ControlRequest (RequestStop)
  , ExecutionDomain (GameplayDomain, InterfaceDomain)
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
  , TaskControlAnswer (..)
  , TaskRequest (..)
  , TickWait (TicksCompleted)
  , admitScheduledTask
  , awaitScheduledAccounting
  , waitTask
  , awaitTicksComplete
  , cancelScheduled
  , forgetControl
  , grantScheduledStep
  , pollTask
  , requestTaskControl
  , retireScheduled
  , scheduledEndpoint
  , scheduledExitRecord
  , scheduledSpec
  , scheduledStatus
  , scheduledSupervised
  , startScheduledOwner
  , ticketTask
  )
import Hetoimasia.Scripting.Lua.Scheduler (ControlResult (..), TimerBackend, systemTimerBackend)

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
  , configUiSpec ∷ !(ScheduledSpec → ScheduledSpec)
    -- ^ Test-only: the last word on the UI owner's configuration (a hold on its thread, where a cancellation can reach it).
  , configAssignHook ∷ !(IO ())
    -- ^ Test-only: run by a control's assignment before it returns, in the interval before the engine admits it.
  , configTaskHook ∷ !(IO ())
    -- ^ Test-only: run inside a task admission, after the session was found to take tasks and before the owner is asked.
  , configWatcherHook ∷ !(IO ())
    -- ^ Test-only: run by a task's watcher, on its own thread, after it has the task's settlement and before it tells it.
  , configTickHook ∷ !(TickPoint → IO ())
    -- ^ Test-only: run by the driver at each point 'TickPoint' names.
  , configAcceptedHook ∷ !(IO ())
    -- ^ Test-only: run inside a task admission after the owner has accepted the task and before the session tracks it. The
    -- interval is not interruptible in production, so an example that holds it must not cancel the admitter.
  , configHandoffHook ∷ !(IO ())
    -- ^ Test-only: run inside a task admission after the owner has accepted the task and the session tracks it, in the
    -- interval before the admission returns.
  , configStopHook ∷ !(StopPoint → IO ())
    -- ^ Test-only: run by a stop at each point 'StopPoint' names.
  , configEscalateHook ∷ !(IO ())
    -- ^ Test-only: run by the gameplay owner's escalation callback, on the owner's thread, before it tells the session
    -- of a failure.
  , configPublishHook ∷ !(PublishPoint → IO ())
    -- ^ Test-only: run by the publication that ends a session, before it takes the publication and after, in the
    -- interval before the snapshot is published.
  , configUiSeesEnd ∷ !Bool
    -- ^ Whether the session waits, after it has published its ending (a failure or a stop), for the UI to have
    -- seen it while the UI serves. The executable does; an example whose UI is moved by hand does not unless it is
    -- the example.
  , configPace ∷ !(Word64 → IO ())
    -- ^ Run after each committed tick of 'runSession'. It paces a session in real time and takes
    -- no part in what a tick contains.
  , configReplay ∷ !(Maybe InputLog)
    -- ^ An input log the session takes its intentions and controls from, and from nothing else (#500 requirement 4): the
    -- driver releases each record to the seam the UI's path uses, before the tick it is for has begun; the UI's offers are
    -- declined and its control requests refused, before they take a place. A log that cannot be replayed under this
    -- configuration is refused before anything starts ('ReplayRefused').
  , configReleaseHook ∷ !(IO ())
    -- ^ Test-only: run by a replay before it releases each record, after the session was found to be running: the
    -- interval in which a stop, a failure or a retirement can be recorded while a release is under way.
  , configUiScenario ∷ !(Maybe Text)
    -- ^ The scenario name the UI behavior reads, when it is not 'configScenario': a replay of a @pause@ log runs gameplay
    -- as that scenario does and its UI as @normal@, which asks for no control of its own.
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
    , configUiSpec = id
    , configAssignHook = pure ()
    , configTaskHook = pure ()
    , configWatcherHook = pure ()
    , configTickHook = const (pure ())
    , configAcceptedHook = pure ()
    , configHandoffHook = pure ()
    , configStopHook = const (pure ())
    , configEscalateHook = pure ()
    , configPublishHook = const (pure ())
    , configUiSeesEnd = True
    , configPace = \_ → pure ()
    , configReplay = Nothing
    , configReleaseHook = pure ()
    , configUiScenario = Nothing
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
  | -- | The engine refused to admit the stop of a gameplay instance. The pending bound leaves the owner a reservation
    -- for each instance, so this does not happen; it is a defect of the sample if it does.
    StopRefused !Text !String
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
  | -- | 'stopSession' was called from a thread other than the application thread's: the supervised waits that settle the
    -- session are that thread's, so another asks through 'requestStop'.
    StopOffApplicationThread
  | -- | 'stepTick' was called from a thread other than the application thread's: the waits that decide a tick are the
    -- supervision handle's, which that thread owns.
    DriverOffApplicationThread
  | -- | 'runSession' was asked to run a session that is not finite.
    SessionNotFinite
  | -- | A session ended with something pending, or with the ledger out of balance: the counters and
    -- what was pending.
    ConservationViolated !Counts !Int
  | -- | The input log cannot be replayed under this configuration; decided before anything started, from the log, the
    -- tick limit and the scenario (the first few problems).
    ReplayRefused ![ReplayProblem]
  | -- | A record the log holds and the checks before the start did not exclude was not admitted when the driver released
    -- it, though the session had not ended: the tick and what was answered. A defect of the sample, never a log's.
    ReplayNotAdmitted !Word64 !String
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
  { domainsHome ∷ !ThreadId
    -- ^ The application thread: the one that created the session, which owns the supervision handle.
  , domainsConfig ∷ !DomainsConfig
  , domainsShared ∷ !Shared
  , domainsControl ∷ !RuntimeControl
  , domainsGameplay ∷ !Started
  , domainsExtras ∷ ![Started]
    -- ^ A test's extra instances on the gameplay owner.
  , domainsUi ∷ !Started
  , domainsFeed ∷ !(Maybe Feed)
    -- ^ The replay's records and what has become of them, when the session is a replay.
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

-- | Where the publication that ends a session is, for a test that holds it.
data PublishPoint = BeforeClaim | AfterClaim
  deriving (Eq, Show)

-- | Where the driver is in a tick, for a test that holds it: the tick has begun and no grant is issued; it is issuing the
-- grant (the session's state was checked and the grant not yet issued: a stop or a failure is not recorded until the grant is
-- issued); it has decided to commit and has not yet taken the commit step; or the step is taken and it has not yet returned.
data TickPoint = BeforeGrant | AtGrant | BeforeCommitStep | AfterCommitStep
  deriving (Eq, Show)

-- | Where a stop is, for a test that holds it: its intent is recorded and admission closed, and nothing has been asked
-- of the instances yet; or the gameplay instance at this position has been asked to stop and the request is recorded.
data StopPoint = StopIntended | StopIssued !Int
  deriving (Eq, Show)

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
  -- A finite session is made only if every record it can accept fits the input log: at most a tick's places and a tick's
  -- pending controls, for each of its ticks. The log's bound is thereby the bound of every valid bounded session, and a log
  -- never has to be cut short.
  forM_ (configTicks config) $ \ticks → do
    -- The digest trace holds the initial state and one entry for each tick, and the input log names ticks up to this
    -- bound: a finite session longer than it would end by exhausting the trace.
    when (ticks > maxSessionTicks) $
      throwIO (BoundsRefused ["a session of " <> show ticks <> " ticks is longer than the " <> show maxSessionTicks <> " ticks a session may have"])
    let most = toInteger ticks * toInteger (boundPlaces (configBounds config) + boundPendingControls (configBounds config))
     in when (most > toInteger maxRecords) $
          throwIO (BoundsRefused ["a session of " <> show ticks <> " ticks can accept " <> show most <> " records, and an input log holds " <> show maxRecords])
  -- A log that cannot be replayed is refused before anything starts, from what is decidable without running: the log, the
  -- tick limit and the scenario's stop. What an execution does afterwards is not predicted.
  forM_ (configReplay config) $ \replay →
    forM_ (NonEmpty.nonEmpty (checkReplayable (configBounds config) (configTicks config) (configStopAfter config) replay)) $ \problems →
      throwIO (ReplayRefused (NonEmpty.toList problems))
  feed ← traverse newFeed (configReplay config)
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
        , setupScenario = fromMaybe (configScenario config) (configUiScenario config)
        , setupLogOnly = isJust (configReplay config)
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
      Right ui → do
        home ← myThreadId
        pure (Domains home config shared control gameplay extras ui feed)
  case outcome of
    Left failure → rollback restore gameplayOwner failure
    Right domains → do
      -- A failure told from now on asks everything the session holds to stop, without waiting.
      writeIORef (sharedOnFailure shared) (quiesceNow domains)
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
    ( (scheduledSpec vm (workerPolicy "gameplay") (gameplayScheduling (configBounds config)))
        { scheduledDomain = GameplayDomain
        , scheduledInstances = Just ((instanceConfigFor config) {instanceControlAdmission = AdmitLogically, instanceEscalate = gameplayEscalation config shared})
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
  configUiSpec
    config
    ( (scheduledSpec vm (workerPolicy "interface") uiScheduling)
        { scheduledDomain = InterfaceDomain
        , scheduledClock = configUiClock config
        , scheduledTimer = configUiTimer config
        , scheduledObserve = \_ → captureView shared
        , scheduledInstances = Just ((instanceConfigFor config) {instanceEscalate = uiEscalation shared})
        , scheduledLifecycle =
            Just (lifecycleGrant [GrantTarget (GrantedEndpoint gameplayEndpoint) [PermitInspect, PermitControl] (Just (assignControl shared))])
        }
    )
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
-- | How many instances an owner holds live at once: the behavior and the instances beside it. The engine's reservations
-- for control are the pending bound and one for the stop of each of these.
liveInstances ∷ Int
liveInstances = 4

instanceConfigFor ∷ DomainsConfig → InstanceConfig
instanceConfigFor config =
  defaultInstanceConfig
    { instanceBounds = InstanceBounds {boundLiveInstances = liveInstances, boundRetainedInstances = 8, boundInvocationQueue = 8, boundInstanceControls = boundPendingControls (configBounds config) + liveInstances}
    , instanceTickDuration = Just (configTickDuration config)
    }

-- | Gameplay's scheduling, from the session's bounds. The owner keeps a task's active slot and its result until the
-- task's settlement is observed, and a live instance's invocation takes an active slot of the same pool, so both
-- are counted: one active slot for each instance the owner may hold live and one for each task the session may hold
-- unobserved ('boundSessionTasks'). However many tasks are unobserved and whichever instances are due, an update
-- always has a slot, and the tick reaches its commit decision with no task of the sample's own to wait for. Queued
-- admissions and retained results are twice that, which covers the two the instance layer reserves for each live
-- instance and each task's, and one grant is outstanding at a time, which is enough (P-6). Control requests are the
-- stops of the tasks the session holds, one at a time (seven active slots, fourteen queued admissions and fourteen
-- retained results by default: three session tasks and four live instances).
gameplayScheduling ∷ Bounds → SchedulerBounds
gameplayScheduling bounds =
  SchedulerBounds
    { boundActiveTasks = active
    , boundQueuedAdmissions = 2 * active
    , boundRetainedResults = 2 * active
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 1
    , boundControlRequests = active
    , boundServiceBudget = Nothing
    }
  where
    active = liveInstances + boundSessionTasks bounds

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
gameplayEscalation ∷ DomainsConfig → Shared → InstanceFailure → IO Escalation
gameplayEscalation config shared failure = do
  configEscalateHook config
  atomically $ do
    tick ← currentTick shared
    forM_ (sessionFailuresOf tick failure) (failSession shared)
  -- The session is told, and the owner's thread goes on: whatever else the session holds is asked to stop, so a wait for a
  -- tick that a surviving instance would keep from completing ends. Asking never waits.
  join (readIORef (sharedOnFailure shared))
  pure Isolate

-- | The session failures an instance's failure tells, in the order they happened: its primary, and then each of what
-- else failed while it ended (the error its @shutdown@ raised) that is a failure of script execution. A failed
-- release is cleanup evidence, fatal under supervision, and is never a session failure, whichever it is of the two.
sessionFailuresOf ∷ Word64 → InstanceFailure → [SessionFailure]
sessionFailuresOf tick failure =
  [sessionFailureOf tick failure | scriptFailure (failureStage failure) (failureError failure)]
    <> [secondaryFailureOf tick failure stage err | (stage, err) ← failureSecondary failure, scriptFailure stage err]

-- | Whether a failure at this stage is a failure of script execution: not a failed release.
scriptFailure ∷ HookStage → InstanceError → Bool
scriptFailure stage err = case (stage, err) of
  (StageRelease, _) → False
  (_, ErrorRelease _) → False
  _ → True

-- | What else failed while the instance ended, as the evidence names it.
secondaryFailureOf ∷ Word64 → InstanceFailure → HookStage → InstanceError → SessionFailure
secondaryFailureOf tick failure stage err =
  SessionFailure
    { failWho = maybe "instance" id (failureName failure)
    , failPhase = Text.toLower (Text.pack (show (failurePhase failure)))
    , failStage = stageText stage
    , failTick = tick
    , failKind = kindText err
    , failMessage = boundedMessage (maybe (Text.pack (show err)) id (errorText err))
    }

-- | The tick a failure is told of at: the tick in progress, or the last committed one.
currentTick ∷ Shared → STM Word64
currentTick shared =
  readTVar (sharedTick shared) >>= \case
    Just working → pure (candidateTick working)
    -- No tick is in progress: the failure belongs to the first tick not yet committed (D-48).
    Nothing → (+ 1) . worldTick <$> readTVar (sharedCommitted shared)

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
  StageRequest endpoint → "request " <> endpoint
  StageConstruct → "construct"

kindText ∷ InstanceError → Text
kindText = \case
  ErrorFault (BoundaryFailed fault) | ScriptFailed _ _ ← boundaryReason fault → "script error"
  ErrorFault _ → "script fault"
  ErrorMissingEntry _ → "missing entry point"
  ErrorRefusedWait _ → "refused wait"
  ErrorRelease _ → "release failure"
  ErrorDelivery _ _ → "delivery failure"
  ErrorRequest _ _ → "required request failure"
  ErrorCadence _ → "cadence failure"
  ErrorExportMissing _ → "missing export module"
  ErrorExportFailed _ → "export module failure"
  ErrorBehavior _ → "behavior refused"

-- | What the instance's code said: the error it raised, when it raised one, and otherwise the engine's rendering.
messageOf ∷ InstanceFailure → Text
messageOf failure = maybe (failureMessage failure) id (errorText (failureError failure))

-- | What an instance's code said in an error, when it was a script error the engine caught.
errorText ∷ InstanceError → Maybe Text
errorText = \case
  ErrorFault (BoundaryFailed fault) → Just $ case boundaryReason fault of
    ScriptFailed _ (ErrorMessage message _) → message
    ScriptFailed _ (ErrorOpaque kind) → "an error value of type " <> kind
    ScriptFailed _ ErrorAbsent → "no error value"
    other → Text.pack (show other)
  _ → Nothing

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
tidOf = instanceTriple

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

-- The accounting and the tasks ------------------------------------------------------

-- | The behavior's instance, as the engine reports it now.
behaviorNow ∷ Started → STM (Maybe InstanceSnapshot)
behaviorNow started = inspectInstance (scheduledEndpoint (startedOwner started)) (startedInstance started)

-- | Run one of the sample's supervised waits, which are the application thread's and one at a time.
serially ∷ Domains → IO a → IO a
serially domains = supervisedWait (domainsShared domains)

-- | Wait for the gameplay owner to have accounted for every grant accepted so far and for the instance endings they
-- caused ('awaitScheduledAccounting', D-47): a failed instance has ended, its @shutdown@ and the release of what it
-- held included, and the application's escalation has been called and has returned. It takes no task, ticket or slot,
-- so it works whatever the session holds. 'AccountingOwnerEnded' says the owner ended first and accounted for nothing:
-- never a completion. It is one of the supervised waits, which only the application thread makes ('serially').
awaitAccounting ∷ Domains → IO AccountingWait
awaitAccounting domains =
  serially domains (awaitScheduledAccounting (domainsControl domains) (startedOwner (domainsGameplay domains)))

-- | Admit a task to the gameplay owner as the session's: if it faults, the session fails, as an instance's
-- failure fails it. A session that has failed, is stopping or has ended takes none: the answer is
-- 'TaskAdmissionClosed' and nothing reaches the owner. An admission that began before the session ended is
-- finished, and tracked, before the ending is published or the settlements are read for it. The owner's acceptance and
-- the session's tracking of the task are not separated by anything that waits: the task is handed over in one
-- transaction ('handOffTask') as soon as the owner has accepted it, so it is tracked and counted whatever interrupts
-- the admitter next, and a task that was not accepted is never counted. Each accepted task has a watcher thread, which
-- tells the session of its settlement as soon as there is one, so a fault is known when it happens and not when the
-- driver next looks.
admitGameplayTask ∷ Domains → TaskRequest → IO TaskAdmission
admitGameplayTask domains request = mask_ $ do
  let shared = domainsShared domains
      config = domainsConfig domains
  entered ← atomically (enterTaskAdmission shared)
  case entered of
    TaskEntryClosed → pure TaskAdmissionClosed
    -- The session holds as many tasks it has not been told the settlement of as 'boundSessionTasks' allows, and the
    -- owner's scheduling has an active slot for each of them beside the instances'.
    TaskEntryFull → pure TaskQueueFull
    TaskEntered →
      ( do
          configTaskHook config
          admission ← admitScheduledTask (scheduledEndpoint (startedOwner (domainsGameplay domains))) request
          case admission of
            TaskAccepted _ ticket → do
              configAcceptedHook config
              -- Registered, and told in the same transaction whether the session still takes work. A halt recorded before this
              -- transaction was recorded without this task in the registry, so whatever quiescence it ran has missed it; one
              -- recorded after finds it. Either way the task is stopped, and by its own admitter in the first case.
              (watched, open) ← atomically ((,) <$> handOffTask shared (maybe "task" id (requestName request)) ticket <*> takesTasks shared)
              startWatcher domains watched
              unless open (issueTaskStops domains)
            _ → pure ()
          configHandoffHook config
          pure admission
      )
        `finally` atomically (leaveTaskAdmission shared)

-- | The thread that waits for a task's settlement, on its own and without supervision (any thread may wait for one), and
-- tells it. Every accepted task settles, even if only as discarded when the owner exits, so it ends.
startWatcher ∷ Domains → Watched → IO ()
startWatcher domains watched =
  void $ forkIOWithUnmask $ \unmask →
    void . try @SomeException $ do
      settlement ← unmask (waitTask (watchedTicket watched))
      configWatcherHook (domainsConfig domains)
      tellTask domains watched settlement

-- | Tell the session of a task's settlement: in one transaction the task leaves the registry and a fault it raised is
-- recorded as a session failure (which closes admission), so each settlement is told once however many threads learn
-- it, and a thread that is interrupted tells nothing half. A fault asks every instance and task to stop, without
-- waiting, whatever the driver is waiting for.
tellTask ∷ Domains → Watched → ScheduledSettlement → IO ()
tellTask domains watched settlement = do
  let shared = domainsShared domains
  faulted ← atomically $ do
    held ← readTVar (sharedTasks shared)
    if watched `notElem` held
      then pure False
      else do
        writeTVar (sharedTasks shared) (filter (/= watched) held)
        case faultOf (settledOutcome settlement) of
          Nothing → pure False
          Just (kind, message) → do
            tick ← currentTick shared
            failSession shared (SessionFailure (watchedName watched) "task" "task" tick kind (boundedMessage message))
            pure True
  when faulted (quiesceNow domains)

-- | What a settlement says of a fault, if it is one.
faultOf ∷ ScheduledOutcome → Maybe (Text, Text)
faultOf = \case
  SettledFaulted fault → Just ("script fault", Text.pack (take 600 (show fault)))
  SettledRefused why → Just ("refused wait", Text.pack (take 600 (show why)))
  _ → Nothing

-- | Tell the session of the settlement of each task that has one, which the driver does after the accounting wait and
-- before the commit step: the accounting wait does not consume a task's result, so a task a tick resumed that faulted in
-- it is told here, whatever its watcher has or has not yet told (a watcher may not have run), and never shifted to the
-- next tick. The admissions in flight are waited for first (brief: an admission waits for nothing), so a task the owner
-- accepted is registered, and read, before the tick is decided. A task admitted or running outside the tick's grants
-- that faults after this reading is later work: it belongs to the first tick not yet committed when it is told (D-48).
watchTasks ∷ Domains → IO ()
watchTasks domains = do
  let shared = domainsShared domains
  atomically (taskAdmissionsDrained shared)
  held ← readTVarIO (sharedTasks shared)
  forM_ held $ \watched → pollTask (watchedTicket watched) >>= mapM_ (tellTask domains watched)

-- | Settle every task the session admitted, which a session that takes no more tasks does once, before its status is
-- decided: each task without a settlement is asked to stop (it need not yield for the stop to reach it, and asking is
-- claimed and recorded without waiting), and its settlement is waited for, with no supervised wait (the owner settles
-- every accepted task), so its fault, if it faulted, is told of. A task the stop cancels has no fault to tell.
settleTasks ∷ Domains → IO ()
settleTasks domains = do
  let shared = domainsShared domains
  void (atomically (taskAdmissionsDrained shared))
  issueTaskStops domains
  let go =
        readTVarIO (sharedTasks shared) >>= \case
          [] → pure ()
          watched : _ → do
            settlement ← waitTask (watchedTicket watched)
            tellTask domains watched settlement
            go
  go

-- | Ask every task the session holds to stop that has not been asked. Each is claimed and then asked in one step that
-- nothing interrupts, and the request never waits.
issueTaskStops ∷ Domains → IO ()
issueTaskStops domains = do
  let endpoint = scheduledEndpoint (startedOwner (domainsGameplay domains))
  held ← readTVarIO (sharedTasks (domainsShared domains))
  forM_ held $ \watched → mask_ $ do
    asked ← atomically (readTVar (watchedStopAsked watched) <* writeTVar (watchedStopAsked watched) True)
    unless asked $ do
      answer ← requestTaskControl endpoint (ticketTask (watchedTicket watched)) RequestStop
      case answer of
        TaskControlAccepted receipt → forgetControl receipt
        TaskControlFull → atomically (writeTVar (watchedStopAsked watched) False) >> throwIO (StopRefused "task" (show answer))
        -- An owner that no longer takes requests is ending, and settles the task as discarded; a task with no live
        -- identity has settled.
        _ → pure ()

-- | Ask every gameplay instance and every task the session holds to stop, once each, without waiting for any. It is what
-- a failure does, as soon as it is told (from the owner's thread, or a task's watcher) and what a stop does first, so that
-- nothing the session holds can keep a wait that the driver or the stop makes from ever ending. Idempotent.
quiesceNow ∷ Domains → IO ()
quiesceNow domains = do
  issueStops domains (zip [0 ∷ Int ..] (domainsGameplay domains : domainsExtras domains))
  issueTaskStops domains

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

-- | Run one gameplay tick as the module header describes, on the application thread: the waits that decide it are the
-- supervision handle's, which that thread owns, so another thread's call raises 'DriverOffApplicationThread'.
stepTick ∷ Domains → IO TickOutcome
stepTick domains = do
  here ← myThreadId
  when (here /= domainsHome domains) (throwIO DriverOffApplicationThread)
  let shared = domainsShared domains
      config = domainsConfig domains
      gameplay = domainsGameplay domains
      owner = startedOwner gameplay
  pending ← failurePending shared
  if pending
    then maybe TickHalted TickFailed <$> publishEnding domains EndedByFailure
    else do
      -- A replay releases the records of the tick that is the next unstarted one, here, before the tick begins and by the
      -- driver alone: the log is the only source of what the tick will hold.
      forM_ (domainsFeed domains) (releaseRecords domains)
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
        -- A failure told between the check above and the begin (a task's watcher, say) is published all the same.
        Nothing → haltedOrFailed domains
        Just (tick, pausedAtBegin) → do
          configTickHook config BeforeGrant
          -- No grant is issued once a failure is told or a stop asked for: the check and the mark that a grant is being
          -- issued are one transaction, and recording a failure or a stop waits for the mark to be cleared, so a grant is
          -- issued wholly before either is recorded, or not at all.
          granted ← mask_ $ do
            proceeding ← atomically $ do
              over ← haltedNow shared
              if over then pure False else True <$ writeTVar (sharedGranting shared) True
            if proceeding
              then
                ( do
                    configTickHook config AtGrant
                    Just <$> grantScheduledStep (scheduledEndpoint owner) (configTickDuration config)
                )
                  `finally` atomically (writeTVar (sharedGranting shared) False)
              else pure Nothing
          accepted ← case granted of
            Nothing → pure False
            Just (GrantAccepted _) → pure True
            -- A grant an owner refuses because a stop (from another thread) has retired it is the ending the session
            -- already decided; one it refuses otherwise is a defect.
            Just other → do
              over ← atomically (haltedNow shared)
              if over then pure False else throwIO (TickNotGranted tick (show other))
          if not accepted
            then haltedOrFailed domains
            else do
              waited ← serially domains (awaitTicksComplete (domainsControl domains) owner)
              -- Account for the tick (every ending its work began, an instance's escalation included, is told when this
              -- returns), tell the faults of the tasks it resumed, and decide: the commit is one atomic step after
              -- this. A failure that begins after the accounting's cutoff is later work (D-48): told before the commit
              -- step it stops this tick, told after it this tick stays committed and the session fails at the next.
              accounted ← awaitAccounting domains
              -- An owner that ended because the session was stopped, or had failed, while the tick was in flight (the
              -- stop retired it from another thread) is the ending the session already decided: the tick is halted,
              -- and nothing is committed whatever it had begun. An owner that ended otherwise is a defect.
              when (waited /= TicksCompleted || accounted /= AccountingComplete) $ do
                over ← atomically (haltedNow shared)
                unless over (throwIO (OwnerEndedDuringTick tick))
              watchTasks domains
              decide domains tick pausedAtBegin

-- | Whether a failure has been told and its publication has not been made.
failurePending ∷ Shared → IO Bool
failurePending shared = atomically $ do
  failed ← failedNow (sharedSession shared)
  state ← readTVar (sharedSession shared)
  pure (failed && sessionEnded state == Nothing)

-- | The outcome of a tick that did not begin because the session no longer runs one: halted, or, if a failure has been told and
-- not yet published, failed, with the one publication the failure owes.
haltedOrFailed ∷ Domains → IO TickOutcome
haltedOrFailed domains = do
  pending ← failurePending (domainsShared domains)
  if pending then maybe TickHalted TickFailed <$> publishEnding domains EndedByFailure else pure TickHalted

-- | What the driver decided after the accounting.
data Verdict
  = VerdictFailed
  | VerdictHalted
  | VerdictIncomplete
  | VerdictCommit !Candidate

-- | Decide a tick that has completed and been accounted for: a failure told of fails the session and commits
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
    -- no update owed; or there was no work to do: gameplay's update never began (the wrapper every gameplay
    -- module's update is given says when it does) and the engine says why: the behavior is paused, was paused
    -- as the tick began, or a control was applied at its boundary. A control is no proof that the update did not
    -- run (a request for the state it is already in changes nothing): an update that began must have finished.
    -- A paused instance may hold an update it will not run.
    acceptable candidate snapshot assigned =
      snapshotExecution snapshot == ExecIdle
        && case snapshotPhase snapshot of
          Active → not (snapshotUpdateOwed snapshot) && (candidateFinished candidate || (not (candidateBegan candidate) && (pausedAtBegin || assigned)))
          Instance.Paused → True
          _ → False

-- | Commit a tick, which is one atomic step: in one transaction that checks, once more, that no failure is recorded and
-- nothing has ended the session, replace the committed world, publish the snapshot, settle the queue's reservations and
-- count the dispositions. A failure recorded before this step stops the tick, and is published instead; one recorded after it
-- leaves the tick committed and the last good one, and fails the session at the next tick (D-48).
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
      -- The digest of the state this step commits is made before the step, from the snapshot it publishes, and joins the
      -- trace in the step's own transaction: a tick that does not commit adds nothing.
      digest ← evaluate (digestSnapshot snapshot)
      configTickHook config BeforeCommitStep
      done ← atomically $ do
        halted ← haltedNow shared
        failed ← failedNow (sharedSession shared)
        working ← readTVar (sharedTick shared)
        if halted || failed || fmap candidateTick working /= Just tick
          then pure (Left failed)
          else do
            writeTVar (sharedCommitted shared) world
            writeTVar (sharedTick shared) Nothing
            appendTrace shared digest
            settle (sharedQueue shared) tick
            modifyTVar' (sharedCounts shared) (countSettled (length (dispApplied dispositions)) (length (dispStale dispositions) + dispStaleOmitted dispositions))
            publisher ← publisherOf shared
            publish publisher prepared >>= \case
              Published → pure (Right ())
              _ → throwSTM (PublicationRefused tick)
      case done of
        Right () → configTickHook config AfterCommitStep >> pure (TickCommitted snapshot)
        Left True → maybe TickHalted TickFailed <$> publishEnding domains EndedByFailure
        Left False → pure TickHalted

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
      var = sharedSession shared
  -- A failed session is quiescent when its failure is published: every gameplay instance has been asked to stop and
  -- has settled (the one that failed has ended, and the peers that were still serving or had work queued run nothing
  -- more), the accounting of what that did is complete, and the tasks it admitted are settled, with the owner alive.
  -- Admission was closed where the failure was recorded. A stop has done all this already, and it is not done twice.
  when (isFailure ending) $ do
    failed ← atomically (failedNow var)
    when failed (settleGameplay domains)
  configPublishHook config BeforeClaim
  built ← atomically $ do
    state ← readTVar var
    evidence ← evidenceNow var
    if isJust (sessionEnded state) || (isNothing evidence && isFailure ending)
      then pure Nothing
      else
        -- Taking the publication waits for another's to finish, and then there is nothing left to publish.
        taskAdmissionsDrained shared >> claimEnding var >>= \case
          False → pure Nothing
          True → do
            committed ← readTVar (sharedCommitted shared)
            dropped ← drain (sharedQueue shared)
            closeQueue (sharedQueue shared)
            writeTVar (sharedTick shared) Nothing
            identity ← snapGameplay <$> readTVar (sharedView shared)
            let places = map fst dropped
                listed = take (boundDroppedListed bounds) places
                omitted = max 0 (length places - boundDroppedListed bounds)
            (dispositions, status, how) ← case (ending, evidence) of
              (EndedByFailure, Just found) → do
                modifyTVar' (sharedCounts shared) (countInvalidated' (length places))
                markPublished var found
                pure (noDispositions {dispInvalidated = listed, dispInvalidatedOmitted = omitted}, Failed found, EndedFailed)
              _ → do
                modifyTVar' (sharedCounts shared) (countDiscarded' (length places))
                pure (noDispositions {dispDiscarded = listed, dispDiscardedOmitted = omitted}, Stopped, EndedStopped)
            pure (Just (GameSnapshot (configSession config) (worldTick committed) committed dispositions status identity, how))
  forM built $ \(snapshot, how) → do
    -- The publication is taken and nothing else publishes, or ends the session, or closes the publisher until it is
    -- made: another call waits in 'claimEnding', so the interval between the claim and the publication is the
    -- publisher's alone. However it ends, the session has ended, so no waiter is left waiting.
    (do
        configPublishHook config AfterClaim
        prepared ← prepare snapshot
        atomically $ do
          publisher ← publisherOf shared
          publish publisher prepared >>= \case
            Published → markEnded var how
            _ → throwSTM (PublicationRefused (snapTick snapshot))
      )
      `onException` atomically (markEnded var how)
    pure snapshot
  where
    isFailure = \case
      EndedByFailure → True
      EndedByStop → False

-- | After a start in which a behavior ended in its init: that is a failure of the session before its first tick,
-- published beside the initial world; a behavior that is neither serving nor failed is a defect of the sample.
settleStart ∷ Domains → IO ()
settleStart domains = do
  let behaviors = domainsGameplay domains : domainsExtras domains
  phases ← atomically (mapM (fmap (fmap snapshotPhase) . behaviorNow) behaviors)
  let unsettled = [phase | Just phase ← phases, phase /= Active]
  unless (null unsettled) $ do
    void (awaitAccounting domains)
    watchTasks domains
  failed ← atomically (failedNow (sharedSession (domainsShared domains)))
  if failed
    then void (publishEnding domains EndedByFailure)
    else unless (null unsettled) $ throwIO (BehaviorDidNotStart "gameplay" (show unsettled))

-- | The one stop of the session, on the application thread, as the module header describes: the thread that created the
-- domains, whose supervision handle the waits are, so another thread asks through 'requestStop' and this raises
-- 'StopOffApplicationThread' if it is called there. It can be called again: it waits for the gameplay behavior to be
-- settled, which waits for a segment that is running to return. It answers how both owners ended. Once the owners are
-- retired it only says how they ended again.
stopSession ∷ Domains → IO Retirement
stopSession domains = do
  let shared = domainsShared domains
  here ← myThreadId
  when (here /= domainsHome domains) (throwIO StopOffApplicationThread)
  retired ← readTVarIO (sharedClosed shared)
  if retired then retireDomains domains else stopLive domains

-- | Ask for the stop from any thread, waiting for nothing but a grant that is being issued (a short call that waits for
-- nothing, so that no grant follows the stop): the stop is recorded and admission closed in one transaction, the
-- driver's next tick is halted, and every gameplay instance and task is asked to stop, so a tick that is in flight or a wait
-- that depends on what the session holds can end. It finalizes nothing: the application thread does that, through
-- 'stopSession' (or 'runSession', which a halted tick returns to), because the waits that settle the session are the
-- supervision handle's, which that thread owns. Asking again asks nothing again.
requestStop ∷ Domains → IO ()
requestStop domains = do
  let shared = domainsShared domains
  atomically $ do
    -- A grant being issued is issued whole first (a short call that waits for nothing).
    granting ← readTVar (sharedGranting shared)
    when granting retry
    _ ← requestStopNow (sharedSession shared)
    closeQueue (sharedQueue shared)
  configStopHook (domainsConfig domains) StopIntended
  quiesceNow domains

-- | A stop of a session whose owners have not been retired.
stopLive ∷ Domains → IO Retirement
stopLive domains = do
  let shared = domainsShared domains
  requestStop domains
  settleGameplay domains
  failed ← atomically (failedNow (sharedSession shared))
  void (publishEnding domains (if failed then EndedByFailure else EndedByStop))
  afterEnding domains

-- | The end of a finite session that ran its last tick, once, whatever else has ended it.
settleFinite ∷ Domains → IO Retirement
settleFinite domains = do
  retired ← readTVarIO (sharedClosed (domainsShared domains))
  ended ← sessionEnded <$> readTVarIO (sharedSession (domainsShared domains))
  if retired || isJust ended then stopSession domains else finishLive domains

-- | The end of a finite session that ran its last tick: the gameplay instances are settled as a stop settles them
-- (a @shutdown@ that raises, or a lease that does not release, is told of before the publication closes), and then
-- either that failure is published, as any failure is, or nothing is: the last tick's snapshot stands.
finishLive ∷ Domains → IO Retirement
finishLive domains = do
  let shared = domainsShared domains
  requestStop domains
  settleGameplay domains
  failed ← atomically (failedNow (sharedSession shared))
  if failed
    then void (publishEnding domains EndedByFailure)
    else -- The ending takes the publication as every ending does, and publishes nothing: another thread's stop is
    -- waited for, not raced.
      atomically $ do
        mine ← claimEnding (sharedSession shared)
        when mine (markEnded (sharedSession shared) EndedFinished)
  afterEnding domains

-- | Settle the gameplay owner's instances and tasks: everything is asked to stop first, without waiting (a stop is cancelled
-- or concurrent with a driver that is waiting for a tick that something the session holds keeps from completing), then each
-- instance is waited for until it has settled, which includes its @shutdown@ and the release of what it held, then the
-- owner's accounting of what those endings caused (the escalation of a @shutdown@ that raised included), so that every
-- failure of the settlement has been told, and last the session's tasks. The engine's reservations for control leave one
-- for each instance, so the stop is admitted whatever the UI holds. The caller has closed admission: an admission that
-- began before is finished and its task asked to stop before the instances are awaited. Everything here is idempotent, and
-- every supervised wait is the application thread's ('serially').
settleGameplay ∷ Domains → IO ()
settleGameplay domains = do
  let started = domainsGameplay domains : domainsExtras domains
  quiesceNow domains
  void (atomically (taskAdmissionsDrained (domainsShared domains)))
  quiesceNow domains
  forM_ started $ \one → void (serially domains (awaitInstance (domainsControl domains) (startedTicket one)))
  void (awaitAccounting domains)
  settleTasks domains

-- | Ask each of these gameplay instances to stop that has not been asked, remembering each that was. An instance is claimed
-- and then asked in one step that nothing interrupts, and the request never waits, so what is remembered is what the engine
-- took, whatever interrupts the asking and whoever asks first (a failure, a stop, the finite end).
issueStops ∷ Domains → [(Int, Started)] → IO ()
issueStops domains started =
  forM_ started $ \(index, one) → do
    issuedNow ← mask_ $ do
      claimed ← atomically $ do
        done ← readTVar (sharedStopsIssued (domainsShared domains))
        if index `elem` done
          then pure False
          else True <$ writeTVar (sharedStopsIssued (domainsShared domains)) (index : done)
      when claimed $ do
        asked ← requestInstanceControl (scheduledEndpoint (startedOwner one)) (startedInstance one) InstanceStop
        case asked of
          InstanceControlFull → do
            atomically (modifyTVar' (sharedStopsIssued (domainsShared domains)) (filter (/= index)))
            throwIO (StopRefused "gameplay" (show asked))
          _ → pure ()
      pure claimed
    when issuedNow (configStopHook (domainsConfig domains) (StopIssued index))

-- | What follows the publication that ends the session: the UI reads the settlements of the controls it asked for,
-- and, when the configuration asks, sees the status that ends the session, while it serves; a UI that has ended
-- abandoned its receipts and has nothing to see. Then the owners are retired.
afterEnding ∷ Domains → IO Retirement
afterEnding domains = do
  let shared = domainsShared domains
      config = domainsConfig domains
  serially domains $ awaitSupervised (domainsControl domains) $ do
    held ← readTVar (sharedReceipts shared)
    serving ← uiServing domains
    when (held > 0 && serving) retry
  when (configUiSeesEnd config) $ do
    ended ← sessionEnded <$> readTVarIO (sharedSession shared)
    forM_ (endingWord =<< ended) $ \word →
      serially domains $ awaitSupervised (domainsControl domains) $ do
        notes ← readTVar (sharedUiNotes shared)
        serving ← uiServing domains
        when (serving && word `notElem` notesSaw notes) retry
  retireDomains domains
  where
    endingWord = \case
      EndedFailed → Just "failed"
      EndedStopped → Just "stopped"
      EndedFinished → Nothing

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
  , reportDigest ∷ !Digest
    -- ^ The digest of the final published snapshot, status included: the state the session ended in. A failure or a stop
    -- after the last committed tick changes it without adding or rewriting an entry of the trace.
  , reportTrace ∷ ![Digest]
    -- ^ The digest of the initial state and then of each committed tick, in tick order: a tick that did not commit adds
    -- nothing, and a failed or stopped session's trace ends where its committed ticks end.
  , reportRecorded ∷ !(Either RecordProblem InputLog)
    -- ^ What the session accepted, as an input log, or why there is none: never a log that has lost a record.
  , reportReplay ∷ !(Maybe ReplayOutcome)
    -- ^ How many of a replayed log's records were released, when the session was a replay.
  }
  deriving (Show)

-- | What a replay released: the records the log holds, and how many were admitted. A session that ends (a failure, a stop)
-- before it reaches a record's tick leaves it unreleased; the replay is then not complete, and is never reported as one.
data ReplayOutcome = ReplayOutcome
  { replayRecords ∷ !Int
  , replayFed ∷ !Int
  }
  deriving (Eq, Show)

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
  retirement ← if stoppedEarly then stopSession domains else settleFinite domains
  -- Both owners have ended: what supervision committed of either is raised, and the statuses the evidence reads are its decisions.
  checkRuntime (domainsControl domains)
  -- The controls a replay released are settled now that nothing can still settle one: read, or abandoned.
  forM_ (domainsFeed domains) (finalizeReplayed domains)
  evidence ← cleanupEvidence domains
  (counts, left, controls, updates, notes, uiFailure, final, trace, recorder) ← atomically $ do
    counts ← readTVar (sharedCounts shared)
    left ← reserved (sharedQueue shared)
    controls ← readTVar (sharedControls shared)
    updates ← readTVar (sharedUpdates shared)
    notes ← readTVar (sharedUiNotes shared)
    uiFailure ← readTVar (sharedUiFailure shared)
    reader ← readerOf shared
    snapshot ← preparedValue . observedValue <$> readSnapshot reader
    held ← readTVar (sharedTrace shared)
    recorded ← readTVar (sharedRecorder shared)
    pure (counts, left, controls, updates, notes, uiFailure, snapshot, toList held, recorded)
  when (left /= 0 || countAccepted counts /= settledTotal counts) $
    throwIO (ConservationViolated counts left)
  replayed ← traverse replayOutcome (domainsFeed domains)
  pure
    SessionReport
      { reportSession = configSession config
      , reportSeed = configSeed config
      , reportScenario = configScenario config
      , reportTicks = snapTick final
      , reportStatus = snapStatus final
      , reportCounts = counts
      , reportControls = controls
      , reportUiUpdates = updates
      , reportUiNotes = notes
      , reportUiFailure = uiFailure
      , reportRetirement = retirement
      , reportEvidence = evidence
      , reportDigest = digestSnapshot final
      , reportTrace = trace
      , reportRecorded = recorderLog recorder
      , reportReplay = replayed
      }

-- The replay ----------------------------------------------------------------------------

-- | A replay's records, indexed by the tick each is for, and what has become of them. Its owner is the driver (the
-- application thread): 'releaseRecords' writes it from 'stepTick', and 'runSession' reads it when the session is over. It
-- lives as long as the session and holds no Lua value.
data Feed = Feed
  { feedRecords ∷ !(Map Word64 [Record])
    -- ^ The log, by tick, each tick's controls first and then its intentions, in the order of their places.
  , feedTotal ∷ !Int
  , feedState ∷ !(TVar FeedState)
  }

data FeedState = FeedState
  { feedReleased ∷ !Word64
    -- ^ The last tick whose records were released: a tick is released once, when it is the next unstarted one.
  , feedFed ∷ !Int
    -- ^ The records admitted.
  , feedReceipts ∷ ![(Int, InstanceControlReceipt)]
    -- ^ The receipts of the controls admitted that have not yet been read, each with its number (how many records had been
    -- released when it was): a receipt is read once, and counted and taken off in the transaction that follows the read.
  }

newFeed ∷ InputLog → IO Feed
newFeed replay = Feed (byTick replay) (length (logRecords replay)) <$> newTVarIO (FeedState 0 0 [])

-- | Release the records of the next unstarted tick, once, as the module header describes: each intention through the seam the
-- UI's path uses ('admitLogged'), each control through the owner's logical admission at its recorded place, before the
-- tick begins. What the records of earlier ticks did is settled first.
--
-- A session that no longer takes work (it failed, is being stopped or retired, or has ended) is a session whose tick will
-- not begin, and releasing is then quiet: it checks first, and it checks again after anything it was refused, since a halt
-- can be recorded at any point between. A refusal that a halt explains (the queue closed, the gameplay instance settled
-- because it was asked to stop) ends the release and changes nothing else: the tick is halted or failed as it would have been
-- for any session, with #499's report. Anything else that is not an admission is a defect, because everything decidable
-- beforehand was checked before the session started.
releaseRecords ∷ Domains → Feed → IO ()
releaseRecords domains feed = do
  settleReplayed domains feed
  let shared = domainsShared domains
      session = configSession (domainsConfig domains)
      -- Admission has ended, for any reason: a failure, a stop, a retirement, the session's end.
      over = atomically ((||) <$> haltedNow shared <*> isClosed (sharedQueue shared))
  next ← atomically (nextUnstarted (sharedQueue shared))
  before ← readTVarIO (feedState feed)
  halted ← over
  when (next > feedReleased before && not halted) $ do
    -- The tick is claimed first: it is released once, and a release that is interrupted is never begun again from the
    -- start, which would find the places it had already taken held.
    atomically (modifyTVar' (feedState feed) (\state → state {feedReleased = next}))
    foldM_ (release shared session over next) True (Map.findWithDefault [] next (feedRecords feed))
  where
    release _ _ _ _ False _ = pure False
    release shared session over tick True record = do
      configReleaseHook (domainsConfig domains)
      case record of
        RecordIntention {} → case intentionOf session record of
          Nothing → pure False
          Just (place, intention) → do
            -- The admission, its count and its record, and the count of what the replay released, are one transaction.
            answer ← atomically $ do
              admitted ← admitLogged shared place intention
              case admitted of
                AdmittedAt _ → fed
                _ → pure ()
              pure admitted
            case answer of
              AdmittedAt _ → pure True
              AtClosed → pure False
              other → throwIO (ReplayNotAdmitted tick (show other))
        RecordControl _ sequence' _ op →
          -- The engine's acceptance and the session's record of it are not separated by anything that is interrupted: the
          -- request never waits, and what follows it is one transaction, so a control the engine took is counted, recorded
          -- and held for its receipt whatever happens next.
          mask_ $ do
            let request = case op of OpPause → InstancePause; OpResume → InstanceResume
                gameplay = domainsGameplay domains
            answer ← requestInstanceControlAt (scheduledEndpoint (startedOwner gameplay)) (startedInstance gameplay) request (ControlSlot tick sequence')
            case answer of
              InstanceControlAccepted receipt → do
                atomically $ do
                  modifyTVar' (sharedControls shared) (bumpAnswer Nothing . bumpOffered)
                  modifyTVar' (sharedControlTicks shared) (Set.insert tick)
                  modifyTVar' (sharedRecorder shared) (appendRecord record)
                  modifyTVar' (feedState feed) (\state → state {feedReceipts = feedReceipts state <> [(feedFed state + 1, receipt)]})
                  fed
                pure True
              refused → do
                -- A halt explains a refusal: it was recorded before the instance was asked to stop, or the owner retired,
                -- and so is visible now. Nothing else does.
                explained ← over
                atomically (modifyTVar' (sharedControls shared) (bumpAnswer (Just (if explained then "closed" else "refused")) . bumpOffered))
                if explained then pure False else throwIO (ReplayNotAdmitted tick (show refused))
    fed = modifyTVar' (feedState feed) (\state → state {feedFed = feedFed state + 1})

-- | Read the settlements of the controls a replay released that have settled, counting each as the UI's read does; the
-- ones that have not are kept. Reading a settlement gives its reservation back, so the read, the count and taking the
-- receipt off are not separated by anything that is interrupted: the read never waits, and what follows it is one
-- transaction, so a receipt is counted exactly once.
settleReplayed ∷ Domains → Feed → IO ()
settleReplayed domains feed = do
  held ← readTVarIO (feedState feed)
  forM_ (feedReceipts held) $ \(number, receipt) →
    mask_ $
      pollInstanceControl receipt >>= \case
        Nothing → pure ()
        Just result →
          atomically $ do
            modifyTVar' (sharedControls (domainsShared domains)) (bumpSettled (controlWord result))
            modifyTVar' (feedState feed) (\state → state {feedReceipts = filter ((/= number) . fst) (feedReceipts state)})
  where
    controlWord = \case
      ControlApplied → "applied"
      ControlAlreadyInState → "already_in_state"
      ControlNoLongerApplicable → "no_longer_applicable"

-- | The session is over: settle what can be, and count each receipt that never was as abandoned, reported apart.
finalizeReplayed ∷ Domains → Feed → IO ()
finalizeReplayed domains feed = do
  settleReplayed domains feed
  left ← feedReceipts <$> readTVarIO (feedState feed)
  atomically $ do
    modifyTVar' (sharedControls (domainsShared domains)) (\counts → counts {controlAbandoned = controlAbandoned counts + length left})
    modifyTVar' (feedState feed) (\state → state {feedReceipts = []})

-- | What the replay released.
replayOutcome ∷ Feed → IO ReplayOutcome
replayOutcome feed = ReplayOutcome (feedTotal feed) . feedFed <$> readTVarIO (feedState feed)

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
