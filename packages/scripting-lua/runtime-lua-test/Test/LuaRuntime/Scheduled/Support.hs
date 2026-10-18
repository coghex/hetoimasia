-- | What the scheduled-owner examples share: a real supervision boundary, a
-- registration of scheduler operations and fixture bindings, a module of tasks
-- written in Lua, an injected clock and a fake timer, and the coordination the
-- examples use instead of sleeping.
--
-- Every fixture hands its caller fresh state. A gate is an 'MVar' a binding waits
-- on, and each gate has a twin the binding opens as it is reached, so an example
-- knows a task is inside a binding by waiting for the twin and not by guessing how
-- long it takes.
module Test.LuaRuntime.Scheduled.Support
  ( -- * The fixture
    SFixture (..)
  , newSFixture
  , effects
  , taskEffects
  , segmentsRun
  , releaseGate
  , awaitEntered
  , cancelQueued
    -- * The clock and the timer
  , Clock (..)
  , newClock
  , setClock
  , advanceClock
  , readClock
    -- * Configurations
  , theModule
  , schedRegistration
  , tasksSource
  , schedLibraries
  , scheduled
  , scheduledWith
  , defaultSchedulerBounds
  , withChunks
    -- * Creating and driving
  , startScheduled
  , expectScheduled
  , admitTask'
  , request
  , accepted
  , awaitIdle
  , awaitEffect
  , awaitScheduledTerminal
  , awaitRegistrations
  , awaitDiagnostics
  , holding
  , outcomeOf
  , taskReturned
  ) where

import Control.Concurrent (ThreadId, myThreadId, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, tryWithContext)
import Control.Monad (join, unless, void)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), listThreads, threadStatus)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, Instant, durationNanoseconds, scriptedInstant, scriptedSource)
import Hetoimasia.Runtime.Supervision (RuntimeControl, WorkerPolicy, WorkerStatus (WorkerLive), awaitSupervised)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Scheduler.Support (FakeTimer (..), allRegs, newFakeTimer, nanoseconds)
import Test.LuaRuntime.Support (Broken (Broken), applicationBoundaryFault, awaitBlockedOnSTM, requiredPolicy)

-- The fixture ------------------------------------------------------------------

-- | What the bindings observe and share.
data SFixture = SFixture
  { sfLog ∷ !(IORef [Text])
  , sfContexts ∷ !(IORef [SegmentContext])
    -- ^ What each segment was about to be handed, newest first.
  , sfObserver ∷ !(IORef (SegmentContext → IO ()))
    -- ^ What else the application does as a segment is about to run.
  , sfOwnerThread ∷ !(MVar ThreadId)
    -- ^ The thread that runs the owner, noted when it first runs a segment.
  , sfGates ∷ !(IORef (Map Text (MVar ())))
  , sfEntered ∷ !(IORef (Map Text (MVar ())))
  , sfEndpoint ∷ !(IORef (Maybe ScheduledEndpoint))
  , sfIds ∷ !(IORef (Map Text ScheduledTaskId))
  , sfAnswers ∷ !(IORef [Text])
    -- ^ What the control requests a script made were answered with.
  , sfTickets ∷ !(IORef (Map Text ScheduledTicket))
  , sfReceipts ∷ !(IORef (Map Text ControlReceipt))
  , sfRuntime ∷ !(IORef (Maybe LuaRuntime))
  , sfSupervision ∷ !(IORef (Maybe RuntimeControl))
  , sfOwner ∷ !(IORef (Maybe ScheduledOwner))
  , sfPrebuilt ∷ !(IORef (IO ()))
    -- ^ A wait built outside any callback, which @fx.probe('prebuilt', ...)@ runs.
  , sfProbe ∷ !(IORef [Text])
    -- ^ What the waits a script attempted were answered with.
  , sfDelay ∷ !(IORef Word64)
    -- ^ How long each @fx.delay()@ takes on the injected clock.
  , sfClock ∷ !Clock
  , sfTimer ∷ !FakeTimer
  }

newSFixture ∷ IO SFixture
newSFixture =
  SFixture
    <$> newIORef [] -- log
    <*> newIORef [] -- contexts
    <*> newIORef (const (pure ())) -- observer
    <*> newEmptyMVar -- owner thread
    <*> newIORef Map.empty -- gates
    <*> newIORef Map.empty -- entered
    <*> newIORef Nothing -- endpoint
    <*> newIORef Map.empty -- ids
    <*> newIORef [] -- answers
    <*> newIORef Map.empty -- tickets
    <*> newIORef Map.empty -- receipts
    <*> newIORef Nothing -- runtime
    <*> newIORef Nothing -- supervision
    <*> newIORef Nothing -- owner
    <*> newIORef (pure ()) -- prebuilt
    <*> newIORef [] -- probe
    <*> newIORef 0 -- delay
    <*> newClock
    <*> newFakeTimer

-- | What the bindings recorded, oldest first.
effects ∷ SFixture → IO [Text]
effects fixture = reverse <$> readIORef (sfLog fixture)

-- | What the tasks recorded, without what the task that holds the owner did.
taskEffects ∷ SFixture → IO [Text]
taskEffects fixture = filter (not . Text.isSuffixOf " holder") <$> effects fixture

-- | What each segment was handed, oldest first.
segmentsRun ∷ SFixture → IO [SegmentContext]
segmentsRun fixture = reverse <$> readIORef (sfContexts fixture)

gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

-- | Let the binding waiting on this gate go on. Harmless twice.
releaseGate ∷ SFixture → Text → IO ()
releaseGate fixture name = gateIn (sfGates fixture) name >>= void . (`tryPutMVar` ())

-- | Wait until a binding has reached this gate.
awaitEntered ∷ SFixture → Text → IO ()
awaitEntered fixture name = gateIn (sfEntered fixture) name >>= readMVar

blockOn ∷ SFixture → Text → IO ()
blockOn fixture name = do
  gateIn (sfEntered fixture) name >>= void . (`tryPutMVar` ())
  gateIn (sfGates fixture) name >>= readMVar

-- The clock --------------------------------------------------------------------

-- | The injected clock: a number of nanoseconds the examples move.
newtype Clock = Clock (IORef Word64)

newClock ∷ IO Clock
newClock = Clock <$> newIORef 0

setClock ∷ SFixture → Word64 → IO ()
setClock fixture n = let Clock ref = sfClock fixture in writeIORef ref n

advanceClock ∷ SFixture → Word64 → IO ()
advanceClock fixture n = let Clock ref = sfClock fixture in atomicModifyIORef' ref (\held → (held + n, ()))

readClock ∷ SFixture → IO Word64
readClock fixture = let Clock ref = sfClock fixture in readIORef ref

-- Registration -----------------------------------------------------------------

ok ∷ Either RegistrationRefusal a → a
ok = either (error . ("registration refused: " <>) . show) id

-- | The registration the examples share. @sched@ holds the scheduler operations a
-- task suspends with; @fx@ the fixture bindings.
schedRegistration ∷ SFixture → Registration
schedRegistration fixture = ok (registration [] [sched, fx])
  where
    sched =
      namespace
        "sched"
        [ yieldOperation "yield"
        , waitOperation "wait_ticks" WaitLogical [SInteger]
        , waitOperation "wait_ns" WaitElapsed [SInteger]
        ]
    fx =
      namespace
        "fx"
        [ stateOperation "record" [SText] [] $ \arguments → do
            case arguments of
              [VText text] → atomicModifyIORef' (sfLog fixture) (\held → (text : held, ()))
              _ → pure ()
            pure []
        , -- What the wait that just ended earned, as the application was told it.
          stateOperation "resume" [] [SInteger, SInteger, SInteger] $ \_ → do
            held ← readIORef (sfContexts fixture)
            pure $ case held of
              context : _ → case contextResume context of
                Just (ResumedLogical tick granted) → [VInteger 1, VInteger (fromIntegral tick), VInteger (nanosOf granted)]
                Just (ResumedElapsed elapsed) → [VInteger 2, VInteger (nanosOf elapsed), VInteger 0]
                Nothing → [VInteger 0, VInteger 0, VInteger 0]
              [] → [VInteger 0, VInteger 0, VInteger 0]
        , stateOperation "block" [SText] [] $ \arguments → do
            case arguments of
              [VText name] → blockOn fixture name
              _ → pure ()
            pure []
        , stateOperation "enter" [SText] [] $ \arguments → do
            case arguments of
              [VText name] → gateIn (sfEntered fixture) name >>= void . (`tryPutMVar` ())
              _ → pure ()
            pure []
        , stateOperation "fail" [SText] [] $ \arguments → do
            case arguments of
              [VText "boundary"] → throwIO applicationBoundaryFault
              [VText "kill"] → throwIO ThreadKilled
              [VText kind] → throwIO (Broken kind)
              _ → pure ()
            pure []
        , -- An attempt, from inside a task, to wait for something: answered with
          -- whether it was refused as a wait from a callback. Anything else it
          -- raises is let through, so a hang or another failure fails the example.
          stateOperation "probe" [SText, SText] [SBoolean] $ \arguments →
            case arguments of
              [VText kind, VText name] → (: []) . VBoolean <$> attempt fixture kind name
              _ → pure [VBoolean False]
        , -- A segment's cost on the injected clock, as the example configured it.
          stateOperation "delay" [] [] $ \_ → do
            readIORef (sfDelay fixture) >>= advanceClock fixture
            pure []
        , -- A segment's cost on the injected clock.
          stateOperation "advance" [SInteger] [] $ \arguments → do
            case arguments of
              [VInteger n] → advanceClock fixture (fromIntegral n)
              _ → pure ()
            pure []
        , -- A script's admission of an ordinary task of the sample module: answered 0 if the
          -- scheduler took it and 1 if it had no room, forgetting its ticket. It never waits.
          stateOperation "spawn" [SText, SText] [SInteger] $ \arguments →
            case arguments of
              [VText entry, VText label] →
                readIORef (sfEndpoint fixture) >>= \case
                  Just held → do
                    answer ← admitScheduledTask held (request entry [VText label] OrdinaryClass OneShot Nothing)
                    -- Its result is forgotten at once: what it holds goes back when it finishes.
                    case answer of
                      TaskAccepted _ ticket → [VInteger 0] <$ forgetTask ticket
                      _ → pure [VInteger 1]
                  Nothing → pure [VInteger 2]
              _ → pure [VInteger 3]
        , -- A script's request to pause, resume or stop a task it names. It never
          -- waits: a request is accepted or refused at once.
          stateOperation "control" [SText, SText] [SInteger] $ \arguments →
            case arguments of
              [VText name, VText operation] → do
                endpoint ← readIORef (sfEndpoint fixture)
                ids ← readIORef (sfIds fixture)
                case (endpoint, Map.lookup name ids) of
                  (Just held, Just identity) →
                    requestTaskControl held identity (requestOf operation) >>= \case
                      TaskControlAccepted _ → pure [VInteger 0]
                      TaskControlFull → pure [VInteger 1]
                      TaskControlClosed → pure [VInteger 2]
                      TaskControlUnknown → pure [VInteger 3]
                  _ → pure [VInteger 4]
              _ → pure [VInteger 5]
        ]
    requestOf = \case
      "resume" → RequestResume
      "stop" → RequestStop
      _ → RequestPause

-- | Attempt a wait of this kind, answering whether it was refused.
attempt ∷ SFixture → Text → Text → IO Bool
attempt fixture kind name = do
  outcome ← tryWithContext @SomeException action
  case outcome of
    Right () → note "waited" >> pure False
    Left (ExceptionWithContext _ failure) → case fromException failure of
      Just (CallbackWaitRefused operation) → note operation >> pure True
      Nothing → throwIO failure
  where
    note entry = atomicModifyIORef' (sfProbe fixture) (\held → (entry : held, ()))
    ticket = Map.lookup name <$> readIORef (sfTickets fixture)
    receipt = Map.lookup name <$> readIORef (sfReceipts fixture)
    action = case kind of
      "wait_task" → ticket >>= maybe (pure ()) (void . waitTask)
      "await_task" → do
        found ← ticket
        control ← readIORef (sfSupervision fixture)
        case (found, control) of
          (Just held, Just supervision) → void (awaitTask supervision held)
          _ → pure ()
      "wait_control" → receipt >>= maybe (pure ()) (void . waitControl)
      "await_control" → do
        found ← receipt
        control ← readIORef (sfSupervision fixture)
        case (found, control) of
          (Just held, Just supervision) → void (awaitControl supervision held)
          _ → pure ()
      "await_ticks" → do
        owner ← readIORef (sfOwner fixture)
        control ← readIORef (sfSupervision fixture)
        case (owner, control) of
          (Just held, Just supervision) → void (awaitTicksComplete supervision held)
          _ → pure ()
      "start" → do
        runtime ← readIORef (sfRuntime fixture)
        case runtime of
          Just held → void (startScheduledOwner held (scheduled fixture "made" requiredPolicy defaultSchedulerBounds))
          Nothing → pure ()
      _ → join (readIORef (sfPrebuilt fixture))

nanosOf ∷ Duration → Int64
nanosOf = fromIntegral . durationNanoseconds

-- The module -------------------------------------------------------------------

-- | The identity of the module every owner loads.
theModule ∷ ModuleRef
theModule = ModuleRef "tasks" "1"

required ∷ Text → [Schema] → [Schema] → EntryPoint
required name = EntryPoint name Required

tasksEntries ∷ [EntryPoint]
tasksEntries =
  [ required "once" [SText] [SInteger]
  , required "spin" [SText, SInteger] [SInteger]
  , required "forever" [SText] []
  , required "wait_ticks" [SText, SInteger] [SInteger]
  , required "sleep" [SText, SInteger] [SInteger]
  , required "fault" [SText] []
  , required "host_fail" [SText] []
  , required "block_in" [SText] []
  , required "closes_cleanly" [SText] []
  , required "closes_badly" [SText] []
  , required "controls" [SText, SText, SText] []
  , required "echo" [SInteger] [SInteger]
  , required "costly" [SText, SInteger, SInteger] [SInteger]
  , required "ticker" [SText, SInteger, SInteger] [SInteger]
  , required "delayed" [SText, SInteger] [SInteger]
  , required "probe" [SText, SText] [SBoolean]
  , required "tick_then_fail" [SText] []
  , required "block_then_fail" [SText, SText] []
  , required "fails_then_close_fails" [SText, SInteger] []
  , required "close_killed" [SText] []
  , required "blocks_then_suspends" [SText, SText] []
  , required "resumes_then_blocks" [SText, SText] [SInteger]
  , required "resumes_blocks_fails" [SText, SText] []
  , required "bad_wait" [] []
  , EntryPoint "absent" Optional [] []
  ]

tasksSource ∷ ByteString
tasksSource =
  Text.encodeUtf8 . Text.unlines $
    [ "function once(label) fx.record(label) return 1 end"
    , "function spin(label, n)"
    , "  for i = 1, n do fx.record(label .. i) sched.yield() end"
    , "  return n"
    , "end"
    , "function forever(label)"
    , "  local i = 0"
    , "  while true do i = i + 1 fx.record(label .. i) sched.yield() end"
    , "end"
    , "function wait_ticks(label, n)"
    , "  fx.record(label .. ' before')"
    , "  sched.wait_ticks(n)"
    , "  local kind, a, b = fx.resume()"
    , "  fx.record(label .. ' after ' .. kind .. ':' .. a .. ':' .. b)"
    , "  return a"
    , "end"
    , "function sleep(label, ns)"
    , "  fx.record(label .. ' before')"
    , "  sched.wait_ns(ns)"
    , "  local kind, a, b = fx.resume()"
    , "  fx.record(label .. ' after ' .. kind .. ':' .. a .. ':' .. b)"
    , "  return a"
    , "end"
    , "function fault(label) fx.record(label) error('task boom') end"
    , "function host_fail(kind) fx.fail(kind) end"
    , "function block_in(name) fx.record('block ' .. name) fx.block(name) fx.record('unblocked ' .. name) end"
    , "function ticker(label, n, every)"
    , "  for i = 1, n do"
    , "    fx.delay()"
    , "    sched.wait_ticks(every)"
    , "    local kind, a, b = fx.resume()"
    , "    fx.record(label .. ' ' .. i .. ' ' .. a .. ':' .. b)"
    , "  end"
    , "  return n"
    , "end"
    , "function delayed(label, n)"
    , "  for i = 1, n do fx.delay() fx.record(label .. i) sched.yield() end"
    , "  return n"
    , "end"
    , "function closes_cleanly(label)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.record(label .. ' closed') end})"
    , "  fx.record(label .. ' suspended')"
    , "  sched.wait_ticks(1)"
    , "  fx.record(label .. ' resumed')"
    , "end"
    , "function closes_badly(label)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.record(label .. ' closing') error('close boom') end})"
    , "  sched.wait_ticks(1)"
    , "  fx.record(label .. ' resumed')"
    , "end"
    , "function controls(label, target, operation)"
    , "  fx.record(label .. ' ' .. operation .. ' ' .. target .. ' -> ' .. fx.control(target, operation))"
    , "  sched.yield()"
    , "  fx.record(label .. ' after')"
    , "end"
    , "function echo(n) return n end"
    , "function costly(label, n, cost)"
    , "  for i = 1, n do fx.advance(cost) fx.record(label .. i) sched.yield() end"
    , "  return n"
    , "end"
    , "function probe(kind, name) return fx.probe(kind, name) end"
    , "function tick_then_fail(kind) sched.wait_ticks(1) fx.fail(kind) end"
    , "function block_then_fail(name, kind) fx.block(name) fx.fail(kind) end"
    , "function fails_then_close_fails(label, yields)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.record(label .. ' closing') fx.fail('close boom') end})"
    , "  if yields == 1 then sched.yield() end"
    , "  error('script failed')"
    , "end"
    , "function resumes_then_blocks(label, name)"
    , "  sched.wait_ticks(1)"
    , "  fx.block(name)"
    , "  return 7"
    , "end"
    , "function resumes_blocks_fails(label, name)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.fail('close boom') end})"
    , "  sched.wait_ticks(1)"
    , "  fx.block(name)"
    , "  error('script failed')"
    , "end"
    , "function blocks_then_suspends(label, name)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.record(label .. ' closed') end})"
    , "  fx.block(name)"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function close_killed(label)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.record(label .. ' closing') fx.fail('kill') end})"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function bad_wait() sched.wait_ticks(0) end"
    ]

-- | The module every scheduled owner of the examples loads.
tasksModule ∷ ModuleSource
tasksModule = ModuleSource theModule tasksSource tasksEntries

schedLibraries ∷ [Library]
schedLibraries = [LibraryBase, LibraryString, LibraryTable, LibraryMath]

-- Configurations ---------------------------------------------------------------

-- | Roomy bounds with quanta of four.
defaultSchedulerBounds ∷ SchedulerBounds
defaultSchedulerBounds =
  SchedulerBounds
    { boundActiveTasks = 16
    , boundQueuedAdmissions = 16
    , boundRetainedResults = 32
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 4
    , boundControlRequests = 8
    , boundServiceBudget = Nothing
    }

-- | A scheduled owner of this label granted both namespaces, with the fixture's
-- injected clock and fake timer, the default policy and these bounds.
scheduled ∷ SFixture → Text → WorkerPolicy → SchedulerBounds → ScheduledSpec
scheduled fixture label worker =
  scheduledWith fixture label ["sched", "fx"] worker

-- | The same, granting these namespaces.
scheduledWith ∷ SFixture → Text → [Text] → WorkerPolicy → SchedulerBounds → ScheduledSpec
scheduledWith fixture label granted worker bounds =
  (scheduledSpec vm worker bounds)
    { scheduledClock = scriptedSource (clockInstant (sfClock fixture))
    , scheduledTimer = ftBackend (sfTimer fixture)
    , scheduledObserve = \context → do
        -- The owner's thread is the one the hook runs on, which is not the thread a
        -- binding's callback runs on: that is a thread of its own.
        thread ← myThreadId
        void (tryPutMVar (sfOwnerThread fixture) thread)
        atomicModifyIORef' (sfContexts fixture) (\held → (context : held, ()))
        readIORef (sfObserver fixture) >>= ($ context)
    }
  where
    vm =
      (vmConfig schedLibraries)
        { vmRegistration = schedRegistration fixture
        , vmPolicy = granted
        , vmOwnerName = label
        , vmModules = [tasksModule]
        }

clockInstant ∷ Clock → IO Instant
clockInstant (Clock ref) = scriptedInstant . nanoseconds <$> readIORef ref

-- | The same configuration running these initial chunks.
withChunks ∷ [(ChunkName, ByteString)] → ScheduledSpec → ScheduledSpec
withChunks chunks spec = spec {scheduledVm = (scheduledVm spec) {vmInitialChunks = chunks}}

-- Creating and driving ---------------------------------------------------------

expectScheduled ∷ ScheduledStart → IO ScheduledOwner
expectScheduled = \case
  ScheduledStarted owner → pure owner
  ScheduledUnavailable failure → throwIO (userError ("expected an owner, found it unavailable: " <> show failure))
  ScheduledRejected → throwIO (userError "expected an owner, found the boundary closed")
  ScheduledEnded → throwIO (userError "expected an owner, found it ended")

-- | Create a scheduled owner and expect it to be ready. Registers its endpoint in
-- the fixture, for the bindings that make requests.
startScheduled ∷ SFixture → LuaRuntime → ScheduledSpec → IO ScheduledOwner
startScheduled fixture runtime spec = do
  owner ← startScheduledOwner runtime spec >>= expectScheduled
  writeIORef (sfEndpoint fixture) (Just (scheduledEndpoint owner))
  pure owner

-- | A request for a task of the sample module's entry point.
request ∷ Text → [Value] → ServiceClass → TaskKind → Maybe Text → TaskRequest
request entry arguments serviceClass kind name =
  TaskRequest
    { requestModule = theModule
    , requestEntry = entry
    , requestArguments = arguments
    , requestClass = serviceClass
    , requestKind = kind
    , requestName = name
    }

-- | Admit a task, expecting it accepted, and register its identity under the
-- name the bindings use.
admitTask' ∷ SFixture → ScheduledOwner → Text → TaskRequest → IO ScheduledTicket
admitTask' fixture owner name taskRequest =
  admitScheduledTask (scheduledEndpoint owner) taskRequest >>= accepted fixture name

accepted ∷ SFixture → Text → TaskAdmission → IO ScheduledTicket
accepted fixture name = \case
  TaskAccepted identity ticket → do
    atomicModifyIORef' (sfIds fixture) (\held → (Map.insert name identity held, ()))
    pure ticket
  TaskQueueFull → throwIO (userError "expected the task to be accepted, found it full")
  TaskAdmissionClosed → throwIO (userError "expected the task to be accepted, found it closed")

-- | Wait until the owner's thread is parked in an STM transaction: it has served
-- everything it was given and is idle.
awaitIdle ∷ SFixture → IO ()
awaitIdle fixture = readMVar (sfOwnerThread fixture) >>= awaitBlockedOnSTM

-- | Wait, without sleeping, until a binding has recorded this.
awaitEffect ∷ SFixture → Text → IO ()
awaitEffect fixture wanted = do
  seen ← effects fixture
  if wanted `elem` seen then pure () else yield >> awaitEffect fixture wanted

-- | Wait until the owner's worker has a terminal status committed by supervision,
-- through a supervised wait, and answer it.
awaitScheduledTerminal ∷ RuntimeControl → ScheduledOwner → IO WorkerStatus
awaitScheduledTerminal control owner =
  awaitSupervised control $
    scheduledStatus owner >>= \case
      WorkerLive → retry
      status → pure status

-- | Wait until the fake timer has been asked for this many registrations in all:
-- the owner has looked at its clock after a wake and armed again. A signal of
-- progress that, unlike idleness, cannot be seen before the owner has acted.
awaitRegistrations ∷ SFixture → Int → IO ()
awaitRegistrations fixture wanted = do
  held ← length <$> allRegs (sfTimer fixture)
  if held >= wanted then pure () else yield >> awaitRegistrations fixture wanted

-- | Block, in STM and so without sleeping, until the owner's diagnostics satisfy
-- this: a signal that something the example needs has happened, such as a task
-- having begun to wait, that does not depend on how long anything took.
awaitDiagnostics ∷ ScheduledOwner → (Diagnostics → Bool) → IO ()
awaitDiagnostics owner wanted =
  atomically $ do
    counts ← scheduledDiagnostics (scheduledEndpoint owner)
    unless (wanted counts) retry

-- | Admit tasks while the owner is held inside a segment, so that they are all
-- admitted before it serves any: the first task blocks in a binding, the body
-- admits the rest, and the gate is then opened. What the body admits is seen by
-- the scheduler in the order the body admitted it, whatever the thread timing.
holding ∷ SFixture → ScheduledOwner → IO a → IO a
holding fixture owner body = do
  ticket ← admitTask' fixture owner "holder" (request "block_in" [VText "holder"] ControlClass OneShot Nothing)
  awaitEntered fixture "holder"
  result ← body
  releaseGate fixture "holder"
  _ ← waitTask ticket
  pure result

-- | Wait for a task's settlement.
outcomeOf ∷ ScheduledTicket → IO ScheduledOutcome
outcomeOf ticket = settledOutcome <$> waitTask ticket

-- | The values a task returned, if it returned any.
taskReturned ∷ ScheduledOutcome → Maybe [Value]
taskReturned = \case
  SettledReturned (Returned values) → Just values
  _ → Nothing

-- | Cancel the owner and wait until the cancellation is demonstrably queued: the
-- helper that delivers it is blocked in its 'throwTo' because the owner is inside
-- a foreign call or a masked region. Releasing a segment after this is releasing
-- it with a cancellation pending.
cancelQueued ∷ ScheduledOwner → IO ()
cancelQueued owner = do
  before ← blockedThrowers
  cancelScheduled owner
  let wait = blockedThrowers >>= \now → unless (now > before) (yield >> wait)
  wait
  where
    blockedThrowers = do
      threads ← listThreads
      statuses ← traverse threadStatus threads
      pure (length [() | ThreadBlocked BlockedOnException ← statuses])
