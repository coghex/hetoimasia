-- | The two owners and the driver: a UI Lua VM owner and a gameplay Lua VM owner created under one
-- supervision boundary, and the loop that grants gameplay its ticks and commits each one
-- (requirements 2, 5, 7, 8 and 13).
--
-- = The owners
--
-- One 'LuaRuntime', two scheduled owners, each with a VM of its own and nothing shared with the
-- other:
--
-- * the /gameplay/ owner, in 'GameplayDomain', whose behavior is a @Periodic@ instance on
--   @LogicalTicks 1@: its @update@ runs once in every tick the driver grants;
-- * the /UI/ owner, in 'InterfaceDomain', whose behavior is a @Periodic@ instance on an
--   @ElapsedEvery@ cadence, on the clock and timer the configuration supplies.
--
-- Each has its own standard libraries, scheduling bounds, initial chunk and @vmPolicy@, over the one
-- registration of "Hetoimasia.Sample.LuaDomains.Registration". Gameplay is started first and the UI
-- second, and they are retired in the opposite order, UI first: the UI is the producer of
-- intentions and the reader of snapshots, so by the time gameplay stops nothing can still be
-- producing for it, and the counters a finite session reports are read after no producer is left.
-- 'retireDomains' is that retirement, and 'withDomains' runs it on every way out.
--
-- = A tick
--
-- 'stepTick' is the driver's one step:
--
-- 1. In one transaction, seal the next unstarted tick of the queue and make the tick's candidate
--    from the committed world and the sealed intentions
--    ("Hetoimasia.Sample.LuaDomains.Candidate"). Admission and sealing are transactions on one
--    variable, so no intention is ever accepted for a tick that has started.
-- 2. Grant gameplay one logical step of the configured duration. Grants are made one at a time, so
--    at most one is outstanding (P-6).
-- 3. Wait for the owner to complete the tick ('awaitTicksComplete').
-- 4. Check that the work finished /successfully/. Completion of the tick says only that the grant
--    was applied and nothing is left that it could run: a task that waits, fails, pauses or stops
--    completes its tick too. The tick commits only if the candidate was finished by gameplay's own
--    @staging.finish()@ and the instance is still active with nothing in flight and no update owed.
--    Otherwise nothing is committed and 'TickNotCompleted' is raised.
-- 5. In one transaction, replace the committed world, publish the snapshot with its dispositions
--    and status, settle the tick's reservations in the queue and count its dispositions. A reader
--    sees the whole tick or none of it.
--
-- A tick held inside a segment (an example's barrier) is a driver that has not got past step 3:
-- it publishes nothing, so the snapshot always shows the last completed tick.
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
  , stepTick
  , runSession
  , SessionReport (..)
  , DomainsDefect (..)
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, retry, throwSTM, writeTVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, fromException, mask, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (Published), SnapshotReader, closeSnapshot, observedValue, publish, readSnapshot, snapshotReader)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Foundation.Worker (awaitCompletion)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), MonotonicSource, durationFromNanoseconds, monotonicSource)
import Hetoimasia.Runtime.Supervision
  ( Disposition (Required)
  , Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , awaitSupervised
  , checkRuntime
  , supervisedWorker
  )
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds, defaultBounds, validateBounds)
import Hetoimasia.Sample.LuaDomains.Candidate (Candidate (..), beginCandidate, commit)
import Hetoimasia.Sample.LuaDomains.Intention (Dispositions (..))
import Hetoimasia.Sample.LuaDomains.Queue (closeQueue, nextUnstarted, reserved, seal, settle)
import Hetoimasia.Sample.LuaDomains.Registration (gameplayNamespaces, sampleRegistration, uiNamespaces)
import Hetoimasia.Sample.LuaDomains.Scripts (facadeChunk, gameplayChunk, gameplayModule, gameplaySource, interfaceModule, interfaceSource)
import Hetoimasia.Sample.LuaDomains.Shared (ScriptedInput, Shared (..), captureView, newShared, scriptedInputs)
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot (..), SessionStatus (Running))
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..), countSettled)
import Hetoimasia.Sample.LuaDomains.World (World (worldTick))
import Hetoimasia.Scripting.Lua.Instance
  ( Execution (ExecIdle)
  , InstanceAdmission (..)
  , InstanceBounds (..)
  , InstanceConfig (..)
  , InstanceId
  , InstanceKind (Periodic)
  , InstancePhase (Active)
  , InstanceRequest (..)
  , InstanceSettlement
  , InstanceSnapshot (..)
  , InstanceTicket
  , Interval (ElapsedEvery, LogicalTicks)
  , admitInstance
  , defaultInstanceConfig
  , inspectInstance
  , isTerminal
  , pollInstance
  )
import Hetoimasia.Scripting.Lua.Owner (Library (..), ModuleRef, ModuleSource (sourceIdentity), VmConfig (..), vmConfig)
import Hetoimasia.Scripting.Lua.Registration (Namespace, Registration, namespaceName)
import Hetoimasia.Scripting.Lua.Runtime (ExitRecord, LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
  ( ExecutionDomain (GameplayDomain, InterfaceDomain)
  , GrantAnswer (GrantAccepted)
  , Quanta (Quanta)
  , Quantum (Quantum)
  , ScheduledOwner
  , ScheduledSpec (..)
  , ScheduledStart (..)
  , SchedulerBounds (..)
  , ServiceClass (OrdinaryClass)
  , TickWait (TicksCompleted)
  , awaitTicksComplete
  , grantScheduledStep
  , retireScheduled
  , scheduledEndpoint
  , scheduledExitRecord
  , scheduledSpec
  , scheduledSupervised
  , startScheduledOwner
  )
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend, systemTimerBackend)

-- | Where an extra namespace is exposed.
data Where = InUi | InGameplay | InBoth
  deriving (Eq, Show)

-- | A namespace beside the sample's own, which only a test configuration supplies.
data Extension = Extension
  { extensionNamespace ∷ !Namespace
  , extensionWhere ∷ !Where
  }

-- | What a session is created from. The clock and timer are the UI owner's: the executable uses
-- the real ones and an example drives the UI owner with an injected clock and a fake timer wake.
-- The two sources are the owners' behaviors, which a configuration may replace; the extensions
-- are the only way a test reaches a binding of its own, and the production configuration has none.
data DomainsConfig = DomainsConfig
  { configBounds ∷ !Bounds
  , configSession ∷ !Word64
    -- ^ The session's identity.
  , configSeed ∷ !Word64
    -- ^ The seed of the gameplay session's random stream.
  , configTicks ∷ !(Maybe Word64)
    -- ^ The last tick of a finite session; 'Nothing' for one that is driven by hand.
  , configTickDuration ∷ !Duration
    -- ^ The logical duration of one gameplay tick.
  , configUiInterval ∷ !Duration
    -- ^ The UI behavior's elapsed cadence.
  , configUiClock ∷ !MonotonicSource
  , configUiTimer ∷ !TimerBackend
  , configInput ∷ ![ScriptedInput]
    -- ^ The fake input source's list.
  , configGameplaySource ∷ !ByteString
  , configUiSource ∷ !ByteString
  , configExtensions ∷ !(Shared → [Extension])
    -- ^ Namespaces beside the sample's own, made over the session's shared state. Only a test
    -- configuration supplies any.
  , configPace ∷ !(Word64 → IO ())
    -- ^ Run after each committed tick of 'runSession'. It paces a session in real time and takes
    -- no part in what a tick contains.
  }

-- | The production configuration: the default bounds, session 1 at seed 1 for twenty ticks of ten
-- milliseconds, the UI updating every two milliseconds on the real clock and timer, the fixed
-- fake input, the sample's own scripts and no extension.
defaultConfig ∷ DomainsConfig
defaultConfig =
  DomainsConfig
    { configBounds = defaultBounds
    , configSession = 1
    , configSeed = 1
    , configTicks = Just 20
    , configTickDuration = tickDuration
    , configUiInterval = positive 2000000
    , configUiClock = monotonicSource
    , configUiTimer = systemTimerBackend
    , configInput = scriptedInputs
    , configGameplaySource = gameplaySource
    , configUiSource = interfaceSource
    , configExtensions = const []
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
  | -- | A behavior was not admitted, or did not become active.
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
  | -- | The tick completed without its work having finished successfully, so nothing was
    -- committed.
    TickNotCompleted !Word64
  | -- | A snapshot was refused because its publisher had closed.
    PublicationRefused !Word64
  | -- | 'runSession' was asked to run a session that is not finite.
    SessionNotFinite
  | -- | A finite session ended with something pending, or with accepted not equal to applied plus
    -- stale: the counters and what was pending.
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
  , domainsUi ∷ !Started
  }

-- | How one owner ended.
data OwnerEnd = OwnerEnd
  { endExit ∷ !(Maybe ExitRecord)
    -- ^ The owner's exit record.
  , endInstance ∷ !(Maybe InstanceSettlement)
    -- ^ The settlement of its behavior instance.
  }
  deriving (Show)

-- | How both owners ended, UI first.
data Retirement = Retirement
  { retiredUi ∷ !OwnerEnd
  , retiredGameplay ∷ !OwnerEnd
  }
  deriving (Show)

-- Creation ---------------------------------------------------------------------------

-- | Run a body over a session: both owners created, ready, with their behaviors active, under this
-- supervision boundary, and retired in order on every way out.
--
-- Retirement is not a release: it waits for each owner's worker to have /actually ended/ (its raw
-- completion, which supervision's latch of the other owner's failure neither shortens nor
-- lengthens), and a segment that is running is waited for, so it can take as long as that segment.
-- It therefore runs in the caller's own masking state, interruptibly, and an interruption does not
-- end it: each is recorded, the wait goes on until both owners have ended, and then what happened is
-- raised, a cancellation first, with the rest kept as cleanup evidence beside it. What both owners
-- used (the shared state their bindings borrow) is never dropped under a Lua call that is still
-- running, and when this returns or raises, from inside the supervision boundary, neither owner is live.
withDomains ∷ RuntimeControl → DomainsConfig → (Domains → IO a) → IO a
withDomains control config body = mask $ \restore → do
  domains ← startDomains restore control config
  outcome ← tryWithContext @SomeException (restore (body domains))
  (_, interruptions) ← retireWith restore domains
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
  shared ← newShared (configBounds config) (configSession config) (configSeed config) (configTicks config) (configInput config)
  runtime ← newLuaRuntime control
  registered ←
    either
      (throwIO . OwnerDidNotStart "registration" . show)
      pure
      (sampleRegistration shared (map extensionNamespace (configExtensions config shared)))
  gameplay ←
    startBehavior
      restore
      control
      runtime
      "gameplay"
      (gameplaySpec shared config registered)
      (sourceIdentity (gameplayModule (configGameplaySource config)))
      (LogicalTicks 1)
  started ←
    tryWithContext @SomeException $
      startBehavior
        restore
        control
        runtime
        "interface"
        (uiSpec shared config registered)
        (sourceIdentity (interfaceModule (configUiSource config)))
        (ElapsedEvery (configUiInterval config))
  case started of
    Right ui → pure (Domains config shared control gameplay ui)
    Left failure → rollback restore (startedOwner gameplay) failure

-- | The gameplay owner's configuration: the gameplay domain, its own libraries, bounds, initial
-- chunk and policy. Its clock and timer are the library's defaults, which a logical owner never
-- reads: gameplay's time moves only when the driver grants a step.
gameplaySpec ∷ Shared → DomainsConfig → Registration → ScheduledSpec
gameplaySpec shared config registered =
  (scheduledSpec vm (workerPolicy "gameplay") gameplayScheduling)
    { scheduledDomain = GameplayDomain
    , scheduledInstances = Just (instanceConfigFor config)
    }
  where
    vm =
      (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
        { vmInitialChunks = [gameplayChunk]
        , vmOwnerName = "gameplay"
        , vmRegistration = registered
        , vmPolicy = gameplayNamespaces <> extensionNames InGameplay shared config
        , vmModules = [gameplayModule (configGameplaySource config)]
        }

-- | The UI owner's configuration: the interface domain, its own libraries (the UI keeps
-- @math.random@), bounds, initial chunk (the validation facade) and policy, on the configured
-- clock and timer, capturing the latest snapshot as each segment is about to run.
uiSpec ∷ Shared → DomainsConfig → Registration → ScheduledSpec
uiSpec shared config registered =
  (scheduledSpec vm (workerPolicy "interface") uiScheduling)
    { scheduledDomain = InterfaceDomain
    , scheduledClock = configUiClock config
    , scheduledTimer = configUiTimer config
    , scheduledObserve = \_ → captureView shared
    , scheduledInstances = Just (instanceConfigFor config)
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

-- | Each owner hosts one behavior instance; the bounds leave room for a second, and satisfy the
-- scheduler's own requirements of them (retained results at least twice the live instances, and
-- a queue of admissions that holds each).
instanceConfigFor ∷ DomainsConfig → InstanceConfig
instanceConfigFor config =
  defaultInstanceConfig
    { instanceBounds = InstanceBounds {boundLiveInstances = 2, boundRetainedInstances = 4, boundInvocationQueue = 8, boundInstanceControls = 4}
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

-- | Create an owner and admit its one behavior, and wait until the behavior is active: gameplay's
-- grants and the UI's cadence start only after the behavior's initialization. An owner that is up
-- when the rest fails is retired, protected, before the failure propagates.
startBehavior ∷ (∀ x. IO x → IO x) → RuntimeControl → LuaRuntime → Text → ScheduledSpec → ModuleRef → Interval → IO Started
startBehavior restore control runtime name spec ref interval = do
  started ← startScheduledOwner runtime spec
  owner ← case started of
    ScheduledStarted owner → pure owner
    ScheduledUnavailable failure → throwIO (OwnerDidNotStart name (show failure))
    ScheduledRejected → throwIO (OwnerDidNotStart name "the supervision boundary had closed")
    ScheduledEnded → throwIO (OwnerDidNotStart name "the owner ended before it was ready")
  outcome ← tryWithContext @SomeException $ do
    admission ← admitInstance (scheduledEndpoint owner) (InstanceRequest ref (Periodic interval) (Just name) OrdinaryClass [])
    case admission of
      InstanceAccepted identity ticket → do
        let behavior = Started owner identity ticket
        awaitActive control behavior name
        pure behavior
      other → throwIO (BehaviorDidNotStart name (show other))
  either (rollback restore owner) pure outcome

-- | Wait, supervised, until the behavior is active; an instance that ended instead is a failure.
awaitActive ∷ RuntimeControl → Started → Text → IO ()
awaitActive control started name =
  awaitSupervised control $
    inspectInstance (scheduledEndpoint (startedOwner started)) (startedInstance started) >>= \case
      Just snapshot
        | snapshotPhase snapshot == Active → pure ()
        | isTerminal (snapshotPhase snapshot) → throwSTM (BehaviorDidNotStart name (show (snapshotPhase snapshot)))
      _ → retry

-- | Retire an owner that came up when the rest of construction failed, and raise the failure, with
-- whatever interrupted the wait kept beside it.
rollback ∷ (∀ x. IO x → IO x) → ScheduledOwner → ExceptionWithContext SomeException → IO a
rollback restore owner failure = do
  interruptions ← stopOwner restore owner
  composeCleanup (Just failure) [("lua domains rollback", interruption) | interruption ← interruptions]
    >>= maybe (rethrowIO failure) rethrowIO

-- Retirement -----------------------------------------------------------------------

-- | Ask an owner to stop and wait until its worker has actually ended: its raw completion, which
-- the supervision latch neither shortens nor lengthens. The wait runs in the caller's state, so it
-- is interruptible; an interruption is recorded and the wait goes on, until the worker has ended.
-- It answers the interruptions, in the order they arrived.
stopOwner ∷ (∀ x. IO x → IO x) → ScheduledOwner → IO [ExceptionWithContext SomeException]
stopOwner restore owner = do
  retireScheduled owner
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

-- | Retire both owners in order and say how each ended, and what interrupted the waiting. Admission
-- ends first, as an owner's does when it stops: nothing is accepted for a tick that will never run.
-- The UI owner is retired and awaited next, being the producer of intentions and the reader of
-- snapshots, then gameplay, and only then does the snapshot's publication end. Every step is
-- idempotent, so retiring again changes nothing.
retireWith ∷ (∀ x. IO x → IO x) → Domains → IO (Retirement, [ExceptionWithContext SomeException])
retireWith restore domains = do
  atomically (closeQueue (sharedQueue (domainsShared domains)))
  uiInterruptions ← stopOwner restore (startedOwner (domainsUi domains))
  gameplayInterruptions ← stopOwner restore (startedOwner (domainsGameplay domains))
  atomically (closeSnapshot (sharedPublisher (domainsShared domains)))
  ui ← endOf (domainsUi domains)
  gameplay ← endOf (domainsGameplay domains)
  pure (Retirement ui gameplay, uiInterruptions <> gameplayInterruptions)
  where
    endOf started = do
      record ← atomically (scheduledExitRecord (startedOwner started))
      settlement ← pollInstance (startedTicket started)
      pure (OwnerEnd record settlement)

-- | Retire both owners, the UI first, and say how each ended. Waiting for an owner that holds a
-- segment waits for the segment to return, as the owners' stop does (nothing is preempted). It can be
-- called again, and after the owners have ended it answers at once.
retireDomains ∷ Domains → IO Retirement
retireDomains domains = do
  (retirement, interruptions) ← retireWith id domains
  raiseAll interruptions
  pure retirement

-- | The latest committed snapshot, read as a UI segment's capture reads it.
latestSnapshot ∷ Domains → IO GameSnapshot
latestSnapshot domains = atomically (preparedValue . observedValue <$> readSnapshot (reader domains))

reader ∷ Domains → SnapshotReader GameSnapshot
reader = snapshotReader . sharedPublisher . domainsShared

-- The driver ------------------------------------------------------------------------

-- | Run one gameplay tick as the module header describes, and answer the snapshot it committed.
stepTick ∷ Domains → IO GameSnapshot
stepTick domains = do
  let shared = domainsShared domains
      config = domainsConfig domains
      gameplay = domainsGameplay domains
      owner = startedOwner gameplay
  tick ← atomically $ do
    next ← nextUnstarted (sharedQueue shared)
    inProgress ← readTVar (sharedTick shared)
    forM_ inProgress $ \working → throwSTM (TickAlreadyInProgress (candidateTick working))
    when (maybe False (next >) (configTicks config)) $ throwSTM (PastFinalTick next)
    committed ← readTVar (sharedCommitted shared)
    -- The queue's ticks and the world's are one numbering; a disagreement is a defect, found before
    -- anything is sealed (a throw abandons the whole transaction).
    when (worldTick committed + 1 /= next) $ throwSTM (TickOutOfSequence next (worldTick committed))
    (tick, sealed) ← seal (sharedQueue shared)
    writeTVar (sharedTick shared) (Just (beginCandidate (configBounds config) committed tick sealed))
    pure tick
  granted ← grantScheduledStep (scheduledEndpoint owner) (configTickDuration config)
  case granted of
    GrantAccepted _ → pure ()
    other → throwIO (TickNotGranted tick (show other))
  waited ← awaitTicksComplete (domainsControl domains) owner
  unless (waited == TicksCompleted) $ throwIO (OwnerEndedDuringTick tick)
  finished ← atomically (completed domains)
  candidate ← maybe (throwIO (TickNotCompleted tick)) pure finished
  let (world, dispositions) = commit candidate
      snapshot = GameSnapshot (configSession config) tick world dispositions Running
  prepared ← prepare snapshot
  atomically $ do
    writeTVar (sharedCommitted shared) world
    writeTVar (sharedTick shared) Nothing
    settle (sharedQueue shared) tick
    modifyTVar' (sharedCounts shared) (countSettled (length (dispApplied dispositions)) (length (dispStale dispositions) + dispStaleOmitted dispositions))
    publish (sharedPublisher shared) prepared >>= \case
      Published → pure ()
      _ → throwSTM (PublicationRefused tick)
  pure snapshot

-- | The candidate of the tick that has just completed, if its work finished successfully: gameplay
-- said so, and the behavior is active with nothing in flight and no update owed.
completed ∷ Domains → STM (Maybe Candidate)
completed domains = do
  working ← readTVar (sharedTick (domainsShared domains))
  let gameplay = domainsGameplay domains
  instanceNow ← inspectInstance (scheduledEndpoint (startedOwner gameplay)) (startedInstance gameplay)
  pure $ case (working, instanceNow) of
    (Just candidate, Just snapshot)
      | candidateFinished candidate
      , snapshotPhase snapshot == Active
      , snapshotExecution snapshot == ExecIdle
      , not (snapshotUpdateOwed snapshot) →
          Just candidate
    _ → Nothing

-- | What a finite session did.
data SessionReport = SessionReport
  { reportSession ∷ !Word64
  , reportSeed ∷ !Word64
  , reportTicks ∷ !Word64
    -- ^ The ticks committed.
  , reportCounts ∷ !Counts
  , reportUiUpdates ∷ !Int
  , reportRetirement ∷ !Retirement
  }
  deriving (Show)

-- | Run a finite session: commit its ticks, pacing as the configuration says, then retire both
-- owners (the UI first, so no producer is left) and read the counters.
--
-- A session conserves its intentions: the queue closed to ticks beyond the last, every accepted
-- intention was for a tick up to it and was settled by that tick's commit, so with the producers
-- gone nothing is pending and accepted equals applied plus stale. If it does not, that is a defect
-- of the sample and 'ConservationViolated' is raised.
runSession ∷ Domains → IO SessionReport
runSession domains = do
  let config = domainsConfig domains
      shared = domainsShared domains
  total ← maybe (throwIO SessionNotFinite) pure (configTicks config)
  forM_ [1 .. total] $ \tick → stepTick domains >> configPace config tick
  retirement ← retireDomains domains
  (counts, left, updates, committed) ← atomically $ do
    counts ← readTVar (sharedCounts shared)
    left ← reserved (sharedQueue shared)
    updates ← readTVar (sharedUpdates shared)
    world ← readTVar (sharedCommitted shared)
    pure (counts, left, updates, worldTick world)
  when (left /= 0 || countAccepted counts /= countApplied counts + countStale counts) $
    throwIO (ConservationViolated counts left)
  pure (SessionReport (configSession config) (configSeed config) committed counts updates retirement)
