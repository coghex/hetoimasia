-- | What the scheduling examples share: a rig that drives a scheduler over
-- scripted segments with an injected clock and a fake timer, so that no example
-- sleeps and none needs a VM.
--
-- A task's cursor is its name. Each segment the host is asked to run is a step
-- popped from that name's script; a name with no steps left completes. Every
-- segment is logged in the order it ran, with what the wait before it handed it,
-- and every close is logged with the thread that made it.
module Test.LuaRuntime.Scheduler.Support
  ( -- * The rig
    Rig (..)
  , RigOptions (..)
  , defaultOptions
  , defaultBounds
  , newRig
  , newRigWith
    -- * Scripts
  , Step
  , script
  , loop
  , cost
  , yielded
  , completed
  , waitTicks
  , waitFor
  , failedWith
    -- * Admitting and driving
  , admit
  , admitSpec
  , taskSpec
  , turn
  , turnsUntilIdle
  , runSegments
  , ran
  , handed
  , closedTasks
  , workAvailable
  , awaitDelivered
  , taskIdAt
  , phase
  , observe
  , diagnostics
  , granted
  , setStop
    -- * Time
  , nanoseconds
  , setClock
  , advanceClock
    -- * The fake timer
  , FakeTimer (..)
  , Reg (..)
  , newFakeTimer
  , liveRegs
  , allRegs
  , fireReg
    -- * Identity
  , scope
    -- * Checking
  , expectRefused
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, orElse, readTVar, writeTVar)
import Control.Exception (SomeException, throwIO)
import Control.Concurrent (ThreadId, myThreadId, yield)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Control.Monad (filterM, join)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (AllowZero)
  , durationFromNanoseconds
  , scriptedInstant
  , scriptedSource
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId (TaskId), TaskName (TaskName))
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Expectation, expectationFailure)
import Test.LuaRuntime.Support (failExample)

-- | One scheduler over scripted segments.
data Rig = Rig
  { rigScheduler ∷ !(Scheduler Text)
  , rigHost ∷ !(TaskHost Text)
  , rigLog ∷ !(IORef [Text])
  , rigHanded ∷ !(IORef [(Text, Int, Maybe Resume)])
  , rigScripts ∷ !(IORef (Map Text [Step]))
  , rigClosed ∷ !(IORef [(TaskId, ThreadId)])
  , rigCloseFailures ∷ !(IORef (Map TaskId SomeException))
  , rigCloseHook ∷ !(IORef (TaskId → IO ()))
  , rigClock ∷ !(IORef Word64)
  , rigClockHook ∷ !(IORef (IO ()))
    -- ^ Run at every reading of the injected clock, before it answers.
  , rigTimer ∷ !FakeTimer
  , rigStop ∷ !(TVar Bool)
  }

-- | What a rig is configured with.
data RigOptions = RigOptions
  { optPolicy ∷ !Policy
  , optBounds ∷ !SchedulerBounds
  }

defaultOptions ∷ RigOptions
defaultOptions = RigOptions fifoPolicy defaultBounds

-- | Roomy bounds with quanta of four, so that an example states the one it is
-- about.
defaultBounds ∷ SchedulerBounds
defaultBounds =
  SchedulerBounds
    { boundActiveTasks = 16
    , boundQueuedAdmissions = 16
    , boundRetainedResults = 32
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 4
    , boundControlRequests = 8
    , boundServiceBudget = Nothing
    }

-- | A segment of a script: what it does, and what it reports.
type Step = IO (SegmentReport Text)

scope ∷ SessionKey
scope = SessionKey (Owner (ModId "scripts") GameplayDomain) (SessionId 1) firstEpoch

newRig ∷ IO Rig
newRig = newRigWith defaultOptions

newRigWith ∷ RigOptions → IO Rig
newRigWith options = do
  logRef ← newIORef []
  handedRef ← newIORef []
  scripts ← newIORef Map.empty
  closed ← newIORef []
  closeFailures ← newIORef Map.empty
  closeHook ← newIORef (const (pure ()))
  clock ← newIORef 0
  clockHook ← newIORef (pure ())
  timer ← newFakeTimer
  stop ← newTVarIO False
  let config =
        SchedulerConfig
          { schedLabel = "test-owner"
          , schedScope = scope
          , schedPolicy = optPolicy options
          , schedBounds = optBounds options
          , schedClock = scriptedSource (join (readIORef clockHook) >> (scriptedInstant . nanoseconds <$> readIORef clock))
          , schedTimer = ftBackend timer
          , schedStopRequested = readTVar stop
          }
  scheduler ← newScheduler config >>= either (\refused → failExample ("the configuration was refused: " <> show refused)) pure
  let host =
        TaskHost
          { hostRun = \run → do
              let name = runCursor run
              modifyIORef' logRef (name :)
              modifyIORef' handedRef ((name, runSegmentNumber run, runResume run) :)
              next ← atomicModifyIORef' scripts $ \table → case Map.lookup name table of
                Just (step : rest) → (Map.insert name rest table, step)
                _ → (table, pure (ReportCompleted name))
              next
          , hostClose = \identity → do
              thread ← myThreadId
              modifyIORef' closed ((identity, thread) :)
              readIORef closeHook >>= \hook → hook identity
              failures ← readIORef closeFailures
              maybe (pure ()) throwIO (Map.lookup identity failures)
          }
  pure (Rig scheduler host logRef handedRef scripts closed closeFailures closeHook clock clockHook timer stop)

-- Scripts ----------------------------------------------------------------------

-- | The steps a name's segments take, in order. When they run out the task
-- completes.
script ∷ Rig → Text → [Step] → IO ()
script rig name steps = modifyIORef' (rigScripts rig) (Map.insert name steps)

-- | A task that yields for ever.
loop ∷ Rig → Text → IO ()
loop rig name = script rig name (repeat (yielded name))

-- | A step that takes this long on the clock before it reports.
cost ∷ Rig → Word64 → Step → Step
cost rig duration step = modifyIORef' (rigClock rig) (+ duration) >> step

yielded ∷ Text → Step
yielded name = pure (ReportYielded name)

completed ∷ Text → Step
completed name = pure (ReportCompleted name)

waitTicks ∷ Text → Word64 → Step
waitTicks name ticks = pure (ReportWaitTicks name ticks)

waitFor ∷ Text → Word64 → Step
waitFor name duration = pure (ReportWaitElapsed name (nanoseconds duration))

failedWith ∷ Text → TaskFailure → Step
failedWith _ failure = pure (ReportFailed failure)

-- Admitting and driving --------------------------------------------------------

-- | The spec of a named task: its name is its cursor, its entry point and its
-- label.
taskSpec ∷ Text → ServiceClass → TaskKind → TaskSpec Text
taskSpec name serviceClass kind =
  TaskSpec
    { specBehavior = BehaviorId "behavior"
    , specEntry = name
    , specName = Just name
    , specClass = serviceClass
    , specKind = kind
    , specCursor = name
    }

admit ∷ Rig → Text → ServiceClass → TaskKind → IO TaskId
admit rig name serviceClass kind = admitSpec rig (taskSpec name serviceClass kind)

admitSpec ∷ Rig → TaskSpec Text → IO TaskId
admitSpec rig wanted =
  atomically (admitTask (rigScheduler rig) wanted) >>= \case
    Admitted identity → pure identity
    AdmitRefused why → failExample ("admission was refused: " <> show why)

-- | One service turn.
turn ∷ Rig → IO TurnReport
turn rig = serviceTurn (rigScheduler rig) (rigHost rig)

-- | Turns until one reports idle, at most this many.
turnsUntilIdle ∷ Rig → Int → IO [TurnReport]
turnsUntilIdle rig = go
  where
    go 0 = pure []
    go budget = do
      report ← turn rig
      if turnEnd report == TurnIdle then pure [report] else (report :) <$> go (budget - 1)

-- | Turns until at least this many segments have run, and the first that many.
runSegments ∷ Rig → Int → IO [Text]
runSegments rig wanted = go (0 ∷ Int)
  where
    go guardCount = do
      segments ← ran rig
      if length segments >= wanted
        then pure (take wanted segments)
        else
          if guardCount > 10000
            then failExample "the turns made no progress"
            else turn rig >> go (guardCount + 1)

-- | The names of the segments that have run, in order.
ran ∷ Rig → IO [Text]
ran rig = reverse <$> readIORef (rigLog rig)

-- | What each segment was handed: its name, its segment number and its resume.
handed ∷ Rig → IO [(Text, Int, Maybe Resume)]
handed rig = reverse <$> readIORef (rigHanded rig)

-- | The continuations closed, in order, with the thread that closed each.
closedTasks ∷ Rig → IO [(TaskId, ThreadId)]
closedTasks rig = reverse <$> readIORef (rigClosed rig)

-- | Whether the owner's wait would return now.
workAvailable ∷ Rig → IO Bool
workAvailable rig = atomically ((awaitWork (rigScheduler rig) >> pure True) `orElse` pure False)

-- | Wait until a thread that is throwing an exception to another has either
-- delivered it or is blocked because its target cannot take it yet. Used to
-- order an interruption against a section that defers it.
awaitDelivered ∷ ThreadId → IO ()
awaitDelivered thrower = do
  status ← threadStatus thrower
  case status of
    ThreadFinished → pure ()
    ThreadDied → pure ()
    ThreadBlocked BlockedOnException → pure ()
    _ → yield >> awaitDelivered thrower

-- | The identity the nth task admitted to a scheduler gets: the engine issues
-- them from zero in order.
taskIdAt ∷ Word64 → TaskId
taskIdAt = TaskId scope . TaskName

phase ∷ Rig → TaskId → IO (Maybe TaskPhase)
phase rig = atomically . taskPhase (rigScheduler rig)

observe ∷ Rig → TaskId → IO (Maybe (TerminalResult Text))
observe rig = atomically . observeTask (rigScheduler rig)

diagnostics ∷ Rig → IO Diagnostics
diagnostics = atomically . readDiagnostics . rigScheduler

-- | Grant a step of this many nanoseconds.
granted ∷ Rig → Word64 → IO GrantAnswer
granted rig duration = atomically (grantStep (rigScheduler rig) (nanoseconds duration))

-- | Ask the owner to stop, or withdraw the request.
setStop ∷ Rig → Bool → IO ()
setStop rig = atomically . writeTVar (rigStop rig)

-- Time --------------------------------------------------------------------------

nanoseconds ∷ Word64 → Duration
nanoseconds n = either (error . show) id (durationFromNanoseconds AllowZero (toInteger n))

setClock ∷ Rig → Word64 → IO ()
setClock rig = writeIORef (rigClock rig)

advanceClock ∷ Rig → Word64 → IO ()
advanceClock rig duration = modifyIORef' (rigClock rig) (+ duration)

-- The fake timer ---------------------------------------------------------------

-- | One registration the scheduler armed.
data Reg = Reg
  { regNumber ∷ !Int
  , regMicroseconds ∷ !Int
  , regWake ∷ IO ()
  , regLive ∷ !(IORef Bool)
  }

instance Show Reg where
  show registration = "registration " <> show (regNumber registration) <> " for " <> show (regMicroseconds registration) <> "us"

-- | A timer backend that arms nothing and fires only when told.
data FakeTimer = FakeTimer
  { ftBackend ∷ !TimerBackend
  , ftRegs ∷ !(IORef [Reg])
  , ftMostLive ∷ !(IORef Int)
  , ftOnCancel ∷ !(IORef (IO ()))
    -- ^ Run by the action that cancels a registration.
  , ftOnArm ∷ !(IORef (IO ()))
    -- ^ Run by the backend after it has made a registration and before it hands
    -- back the action that cancels it: the window an asynchronous exception can
    -- fall in.
  }

newFakeTimer ∷ IO FakeTimer
newFakeTimer = do
  registrations ← newIORef []
  mostLive ← newIORef 0
  onArm ← newIORef (pure ())
  onCancel ← newIORef (pure ())
  let arm microseconds wake = do
        number ← (+ 1) . length <$> readIORef registrations
        live ← newIORef True
        modifyIORef' registrations (<> [Reg number microseconds wake live])
        liveNow ← length <$> (readIORef registrations >>= filterM (readIORef . regLive))
        modifyIORef' mostLive (max liveNow)
        join (readIORef onArm)
        pure (join (readIORef onCancel) >> writeIORef live False)
  pure (FakeTimer (TimerBackend arm) registrations mostLive onCancel onArm)

-- | The registrations that are armed and neither cancelled nor fired.
liveRegs ∷ FakeTimer → IO [Reg]
liveRegs timer = readIORef (ftRegs timer) >>= filterM (readIORef . regLive)

-- | Every registration ever armed, oldest first.
allRegs ∷ FakeTimer → IO [Reg]
allRegs = readIORef . ftRegs

-- | Fire a registration by hand, as its timer would on expiry. It may have been
-- cancelled or replaced since: that is a stale wake.
fireReg ∷ Reg → IO ()
fireReg registration = writeIORef (regLive registration) False >> regWake registration

-- Checking ----------------------------------------------------------------------

expectRefused ∷ Show a ⇒ a → Expectation
expectRefused answer = expectationFailure ("expected a refusal, found " <> show answer)
