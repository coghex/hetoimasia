{-# LANGUAGE OverloadedStrings #-}

-- | What the facade's examples share: a world of a real content root, inventory and read pool (the
-- module coordinator's session), recording sinks for authored output, an injected clock and a fake timer,
-- and real supervised Lua owners whose behavior instances are handed the real facade and run authored
-- Lua the example wrote into the content tree.
--
-- Evidence from the real adapters and evidence that is injected are kept apart by name: the content,
-- the pool, the coordinator, the data service, the facade and the owners are real; the sinks, the clock,
-- the timer, the admission state and the failure boundary are the controlled endpoints the facade is
-- injected with.
--
-- Nothing sleeps. An example knows what has happened from the authored output (its Lua prints what it
-- saw), from a gate it holds or from STM it blocks in, and the whole example is bounded.
module Test.LuaEngine.Facade.Support
  ( -- * The world
    World (..)
  , withWorld
  , withWorldUsing
  , fatalWorld
  , Layout (..)
  , Session (..)
  , outLines
  , errLines
  , awaitOut
  , awaitErr
  , setAdmission
  , setStatus
  , quitsSeen
  , terminalsSeen
  , failTerminals
  , failuresSeen
  , setClock
  , advanceClock
  , setClockStep
  , setFacadeLag
  , attemptFvm
  , failReports
  , setTickOverride
  , holdSink
  , releaseSink
  , failSinkOn
  , failFlushes
  , awaitSinkEntered
  , awaitBlockedOnSTM
  , worldClock
  , worldTimer
  , FakeTimer
  , fireTimers
  , liveTimers
  , liveRegistrations
  , awaitTimers
  , armedTimers
  , awaitArmed
  , awaitWaiting
  , pumpUntil
  , stepNext
  , Stepped (..)
  , stepIfRegistered
  , tickAndStepUntil
  , stepUntil
  , stepUntilWithin
  , stepOnce
  , tickNext
  , tickUntil
  , explainSteps
  , outLinesSTM
  , timerBackend
  , timerOwner
  , Parking
  , newParking
  , parkedWhile
  , timerOwnerInstance
  , forgetTimerOwner

    -- * VMs
  , Fvm (..)
  , VmShape (..)
  , gameplayShape
  , withOneGraphics
  , presentationShape
  , withFvm
  , ownerTick

    -- * Instances
  , Spawned (..)
  , spawn
  , admitOnly
  , admitWith
  , bootPath
  , awaitActive
  , settledOf
  , phaseOf
  , phaseOfSTM
  , settledFailure
  , requestFailureOf
  , stopSpawned
  , tickBy
  , grantTick
  , awaitTickDone
  , awaitEnded

    -- * Authoring
  , luaMain
  , dumpPrelude
  , tryPrelude
  , Script (..)
  , script
  , scriptSource
  , withOne
  , withOneIn
  , mainPath

    -- * Re-exports
  , Role (..)
  , BootOutcome (..)
  , module Hetoimasia.LuaEngine.Facade
  ) where

import Control.Concurrent (ThreadId, myThreadId, yield)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, bracket_, catch, finally, fromException, onException, throwIO, tryWithContext)
import Control.Monad (filterM, forM, forM_, join, replicateM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Unique (Unique, hashUnique, newUnique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero, RequirePositive), MonotonicSource, durationFromNanoseconds, durationNanoseconds, scriptedInstant, scriptedSource)
import Hetoimasia.LuaEngine.Behavior (behaviorRequest)
import Hetoimasia.LuaEngine.Boot (ContentConfiguration (..), contentConfiguration)
import Hetoimasia.LuaEngine.Data (dataService, newByteBankFor)
import Hetoimasia.LuaEngine.Facade
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Modules
  ( BootOutcome (..)
  , Coordinator
  , ModuleSpec (..)
  , attachLoader
  , awaitBoot
  , bootModule
  , coordinatorPlan
  , moduleIdentity
  , withModuleCoordinator
  )
import Hetoimasia.LuaEngine.Profile (Profile, fixedM1Profile)
import Hetoimasia.LuaEngine.Request (m1Requests)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Loading (LoaderEndpoint)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..))
import Test.HUnit.Lang (HUnitFailure, assertFailure)
import Test.Hspec (expectationFailure)
import Test.LuaEngine.Modules.Support (Layout (..), ReaderOf, Session (..), key', realReader, withSessionLimits)
import Test.Support.Bounded (bounded)

-- The world ----------------------------------------------------------------------------------------

-- | Everything an example shares: the session of real content, the recording sinks and the controlled
-- endpoints the facade is injected with.
data World = World
  { wSession ∷ !Session
  , wProfile ∷ !Profile
  , wOutput ∷ !Output
  , wLines ∷ !(TVar [(Stream, Text)])
  , wFlushes ∷ !(TVar Int)
  , wAdmission ∷ !(TVar AdmissionState)
  , wFailures ∷ !(TVar [EngineFailure])
  , wClock ∷ !(IORef Word64)
  , wClockStep ∷ !(IORef Word64)
  -- ^ How far each read of the injected clock moves it on afterwards: nothing, unless an example wants time
  -- to pass between two reads that no segment boundary separates.
  , wSinkBlock ∷ !(TVar (Maybe Text))
  -- ^ A line the recording sinks hold the writer on, until it is cleared: a slow sink.
  , wSinkFail ∷ !(TVar (Maybe Text))
  -- ^ A line the recording sinks raise on: a sink that fails.
  , wFlushFail ∷ !(TVar Bool)
  -- ^ Whether a flush raises.
  , wSinkEntered ∷ !(TVar [Text])
  -- ^ Every line a sink was handed, in the order it was handed, whether or not it was written.
  , wTickOverride ∷ !(IORef (Maybe Word64))
  -- ^ A tick the facade is told instead of the owner's, to inject a tick no Lua integer holds.
  , wReportFails ∷ !(IORef Bool)
  -- ^ Whether the injected boundary for engine failures raises, after recording the failure it was handed.
  , wFacadeLag ∷ !(IORef Word64)
  -- ^ How far behind the owner's clock the facade's own reads of it are: nothing, unless an example wants
  -- the facade to check a wait against an earlier reading than the scheduler places it against.
  , wTimer ∷ !FakeTimer
  , wIds ∷ !InstanceIds
  , wControl ∷ !RuntimeControl
  , wStatus ∷ !(TVar StatusSample)
  -- ^ The status the injected session endpoints answer: what a presentation segment captures at its entry.
  , wQuits ∷ !(TVar Int)
  -- ^ How many times the facade asked the (injected) session for a normal stop.
  , wTerminals ∷ !(TVar [TerminalContext])
  -- ^ Every terminal latch the facade asked for, in order; the first is the one the session would claim.
  , wTerminalFail ∷ !(IORef Bool)
  -- ^ Whether the injected terminal latch raises, after recording that it was asked for.
  }

-- | Run an example over a world: a temporary content root with these files, scanned; the session's
-- pool; recording sinks; real supervision. However it ends, every gate the session holds is open.
withWorld ∷ Profile → Layout → (World → RuntimeControl → LuaRuntime → IO a) → IO a
withWorld = withWorldUsing realReader

-- | The same over a pool whose reader is made by this function from the real one: an injected failure of the
-- reader for the paths an example names.
withWorldUsing ∷ ReaderOf → Profile → Layout → (World → RuntimeControl → LuaRuntime → IO a) → IO a
withWorldUsing readerOf profile layout body = do
  configuration ← either (\refused → assertFailure ("the profile's content configuration was refused: " <> show refused)) pure (contentConfiguration profile)
  withSessionLimits (Just (configContentLimits configuration, configInventoryLimits configuration)) profile (2, 12) readerOf layout $ \session control runtime → do
    linesVar ← newTVarIO []
    flushes ← newTVarIO 0
    admission ← newTVarIO AdmissionOpen
    failures ← newTVarIO []
    clock ← newIORef 0
    step ← newIORef 0
    override ← newIORef Nothing
    lag ← newIORef 0
    reportFails ← newIORef False
    timer ← newFakeTimer
    ids ← newInstanceIds
    block ← newTVarIO Nothing
    failOn ← newTVarIO Nothing
    flushFail ← newTVarIO False
    entered ← newTVarIO []
    status ← newTVarIO (StatusSample False Nothing Nothing)
    quits ← newTVarIO 0
    terminals ← newTVarIO []
    terminalFail ← newIORef False
    withOutput (recording Stdout linesVar flushes block failOn flushFail entered) (recording Stderr linesVar flushes block failOn flushFail entered) $ \output →
      body (World session profile output linesVar flushes admission failures clock step block failOn flushFail entered override reportFails lag timer ids control status quits terminals terminalFail) control runtime
  where
    recording stream linesVar flushes block failOn flushFail entered =
      OutputSink
        { sinkLine = \line → do
            atomically (modifyTVar' entered (<> [line]))
            atomically (readTVar block >>= \held → when (held == Just line) retry)
            failing ← readTVarIO failOn
            when (failing == Just line) (throwIO (userError "the sink failed"))
            atomically (modifyTVar' linesVar (<> [(stream, line)]))
        , sinkFlush = do
            failing ← readTVarIO flushFail
            when failing (throwIO (userError "the flush failed"))
            atomically (modifyTVar' flushes (+ 1))
        }

-- | An example whose owner is expected to end in a failure of the application's own, which supervision
-- raises at the boundary: answers the engine failures the facade reported and the failure raised. A failed
-- assertion is raised as itself.
fatalWorld ∷ Profile → Layout → (World → RuntimeControl → LuaRuntime → IO ()) → IO ([EngineFailure], ExceptionWithContext SomeException)
fatalWorld profile layout body = do
  seen ← newIORef []
  outcome ← tryWithContext @SomeException (withWorld profile layout (\world control runtime → body world control runtime `finally` (failuresSeen world >>= writeIORef seen)))
  case outcome of
    Left failure@(ExceptionWithContext _ raised)
      | Just (_ ∷ HUnitFailure) ← fromException raised → throwIO raised
      | otherwise → (\reported → (reported, failure)) <$> readIORef seen
    Right () → assertFailure "expected the owner to fail, but the example returned"

-- | What was written to stdout, in order.
outLines ∷ World → IO [Text]
outLines world = streamLines Stdout <$> readTVarIO (wLines world)

-- | 'outLines' in a transaction, for a stop condition.
outLinesSTM ∷ World → STM [Text]
outLinesSTM world = streamLines Stdout <$> readTVar (wLines world)

-- | What was written to stderr, in order.
errLines ∷ World → IO [Text]
errLines world = streamLines Stderr <$> readTVarIO (wLines world)

streamLines ∷ Stream → [(Stream, Text)] → [Text]
streamLines wanted written = [line | (stream, line) ← written, stream == wanted]

-- | Block, in STM, until stdout holds at least this many lines, and answer them.
awaitOut ∷ World → Int → IO [Text]
awaitOut world wanted = atomically $ do
  found ← streamLines Stdout <$> readTVar (wLines world)
  if length found >= wanted then pure found else retry

-- | The same for stderr.
awaitErr ∷ World → Int → IO [Text]
awaitErr world wanted = atomically $ do
  found ← streamLines Stderr <$> readTVar (wLines world)
  if length found >= wanted then pure found else retry

-- | Change the session's admission state, as the session coordinator would.
setAdmission ∷ World → AdmissionState → IO ()
setAdmission world = atomically . writeTVar (wAdmission world)

-- | Set the status the injected session endpoints answer from now on.
setStatus ∷ World → StatusSample → IO ()
setStatus world = atomically . writeTVar (wStatus world)

-- | From now on the injected terminal latch raises, after recording that it was asked for.
failTerminals ∷ World → IO ()
failTerminals world = writeIORef (wTerminalFail world) True

-- | How many normal stops the facade has asked the injected session for.
quitsSeen ∷ World → IO Int
quitsSeen = readTVarIO . wQuits

-- | The terminal latches the facade has asked the injected session for, in order.
terminalsSeen ∷ World → IO [TerminalContext]
terminalsSeen = readTVarIO . wTerminals

-- | The engine failures the facade reported through its boundary.
failuresSeen ∷ World → IO [EngineFailure]
failuresSeen = readTVarIO . wFailures

-- | Set the injected clock, in nanoseconds.
setClock ∷ World → Word64 → IO ()
setClock world = writeIORef (wClock world)

-- | From now on every read of the injected clock moves it on by this many nanoseconds afterwards.
setClockStep ∷ World → Word64 → IO ()
setClockStep world = writeIORef (wClockStep world)

-- | Tell the facade this tick instead of the owner's (or the owner's again, with 'Nothing').
setTickOverride ∷ World → Maybe Word64 → IO ()
setTickOverride world = writeIORef (wTickOverride world)

-- | Hold the writer of this line inside its sink until 'releaseSink'.
holdSink ∷ World → Text → IO ()
holdSink world = atomically . writeTVar (wSinkBlock world) . Just

-- | Let a held writer go.
releaseSink ∷ World → IO ()
releaseSink world = atomically (writeTVar (wSinkBlock world) Nothing)

-- | Make the sinks raise on this line.
failSinkOn ∷ World → Text → IO ()
failSinkOn world = atomically . writeTVar (wSinkFail world) . Just

-- | Make every flush raise.
failFlushes ∷ World → IO ()
failFlushes world = atomically (writeTVar (wFlushFail world) True)

-- | Block, in STM, until a sink has been handed this line.
awaitSinkEntered ∷ World → Text → IO ()
awaitSinkEntered world line = bounded (atomically (readTVar (wSinkEntered world) >>= \found → when (line `notElem` found) retry))

-- | Wait until a thread is parked in an STM transaction. A thread that has ended, or that is parked
-- anywhere else for good, is a failure and not a wait that never returns: the bound turns a thread that
-- never parks into one, and a finished thread fails at once.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM thread = bounded loop
  where
    loop =
      threadStatus thread >>= \case
        ThreadBlocked BlockedOnSTM → pure ()
        ThreadFinished → expectationFailure "the thread ended instead of waiting in a transaction"
        ThreadDied → expectationFailure "the thread died instead of waiting in a transaction"
        _ → yield >> loop

-- | Move the injected clock on.
advanceClock ∷ World → Word64 → IO ()
advanceClock world delta = readIORef (wClock world) >>= writeIORef (wClock world) . (+ delta)

-- | Read the injected clock, then move it on by its step.
clockDuration ∷ World → IO Duration
clockDuration world = do
  now ← atomicModifyIORef' (wClock world) (\current → (current, current))
  step ← readIORef (wClockStep world)
  when (step /= 0) (atomicModifyIORef' (wClock world) (\current → (current + step, ())))
  either (\refused → assertFailure ("the clock is not a duration: " <> show refused)) pure (durationFromNanoseconds AllowZero (toInteger now))

-- | The injected clock as the facade reads it: the owner's reading less the lag, so that an example can have the
-- facade check a wait against an earlier moment than the scheduler places it at.
laggingDuration ∷ World → IO Duration
laggingDuration world = do
  now ← clockDuration world
  lag ← readIORef (wFacadeLag world)
  let behind = max 0 (toInteger (durationNanoseconds now) - toInteger lag)
  either (\refused → assertFailure ("the lagging clock is not a duration: " <> show refused)) pure (durationFromNanoseconds AllowZero behind)

-- | From now on the injected boundary for engine failures raises after it has recorded one.
failReports ∷ World → IO ()
failReports world = writeIORef (wReportFails world) True

-- | From now on the facade's reads of the clock are this many nanoseconds behind the owner's.
setFacadeLag ∷ World → Word64 → IO ()
setFacadeLag world = writeIORef (wFacadeLag world)

-- | The injected clock as the monotonic source an owner, a facade or a session is configured with.
worldClock ∷ World → MonotonicSource
worldClock world = scriptedSource (scriptedInstant <$> clockDuration world)

-- | The world's fake timer as the backend a session is configured with: its registrations belong to no owner the step
-- ('stepNext') follows.
worldTimer ∷ World → TimerBackend
worldTimer world = timerBackend world Nothing

-- Parking ------------------------------------------------------------------------------------------

-- | The owner threads an example's own hold points have parked on purpose (a gate an adapter hook waits at, a fixture's wait),
-- while they are parked. Written only by 'parkedWhile'; read by the step, which does not wait for a parked owner's turn to end.
newtype Parking = Parking (TVar (Set.Set ThreadId))

newParking ∷ IO Parking
newParking = Parking <$> newTVarIO Set.empty

-- | Run a hold point's wait with the calling thread marked parked, and unmarked however the wait ends.
parkedWhile ∷ Parking → IO a → IO a
parkedWhile (Parking held) wait = do
  thread ← myThreadId
  bracket_ (atomically (modifyTVar' held (Set.insert thread))) (atomically (modifyTVar' held (Set.delete thread))) wait

-- The fake timer -----------------------------------------------------------------------------------

-- | A timer that fires only when the example says.
--
-- What it holds: the live registrations, in arming order, each with the owner that armed it (one 'withFvm' made; none for
-- 'worldTimer'), its length and its deadline (the injected clock when it was armed, plus its length); how many were armed in
-- all; the owners 'withFvm' made, by a label, with whether the step waits for their turns and their admitted instances; and the
-- owners the step woke whose turn has not ended. A registration is dropped once it is no longer live, when the next one is
-- armed. The owners write the registrations (arming, and a cancellation clearing the live flag); the step owns the flags it
-- clears when it claims and the in-turn marks.
data FakeTimer = FakeTimer
  { ftRegistrations ∷ !(TVar [Registration])
  , ftArmed ∷ !(TVar Int)
  , ftOwners ∷ !(TVar (Map.Map Unique TimerOwner))
  , ftInTurn ∷ !(TVar (Set.Set Unique))
  }

-- | One registration an owner armed.
data Registration = Registration
  { regOwner ∷ !(Maybe Unique)
  , regMicros ∷ !Int
  , regDeadline ∷ !Word64
  -- ^ In nanoseconds of the injected clock: when it was armed, plus its length.
  , regWake ∷ IO ()
  , regLive ∷ !(TVar Bool)
  }

-- | An owner of the world's timer, as the step knows it.
data TimerOwner = TimerOwner
  { toLabel ∷ !Text
  , toThread ∷ !(Maybe ThreadId)
  -- ^ The owner's thread, recorded when it first arms (an owner arms only on its own thread).
  , toParking ∷ !(Maybe Parking)
  , toTracked ∷ !Bool
  -- ^ Whether the step waits for the end of a turn it started: an owner whose instances run on elapsed time (a presentation
  -- VM) arms its next registration at the end of every turn in which one of them is initializing or serving.
  , toInstances ∷ ![STM Bool]
  -- ^ For each instance admitted to it, whether it is initializing or serving.
  }

newFakeTimer ∷ IO FakeTimer
newFakeTimer = FakeTimer <$> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO Map.empty <*> newTVarIO Set.empty

-- | The backend an owner is configured with: each registration is armed as this owner's (or no owner's), at the injected
-- clock's reading plus its length, and arming ends the owner's turn as far as the step is concerned.
timerBackend ∷ World → Maybe Unique → TimerBackend
timerBackend world owner = TimerBackend $ \microseconds wake → do
  let timer = wTimer world
  now ← readIORef (wClock world)
  thread ← myThreadId
  live ← newTVarIO True
  atomically $ do
    forM_ owner $ \key → modifyTVar' (ftOwners timer) (Map.adjust (\known → known {toThread = Just thread}) key)
    kept ← filterM (readTVar . regLive) =<< readTVar (ftRegistrations timer)
    writeTVar (ftRegistrations timer) (kept <> [Registration owner microseconds (now + fromIntegral microseconds * 1000) wake live])
    modifyTVar' (ftArmed timer) (+ 1)
    forM_ owner (modifyTVar' (ftInTurn timer) . Set.delete)
  pure (atomically (writeTVar live False))

-- | Make an owner of the world's timer known to the step, by this label, with where its parking is marked, followed or not:
-- answers its key.
timerOwner ∷ World → Text → Maybe Parking → Bool → IO Unique
timerOwner world label parking tracked = do
  key ← newUnique
  atomically (modifyTVar' (ftOwners (wTimer world)) (Map.insert key (TimerOwner (label <> "#" <> Text.pack (show (hashUnique key))) Nothing parking tracked [])))
  pure key

-- | An instance admitted to this owner: whether it is initializing or serving.
timerOwnerInstance ∷ World → Unique → STM Bool → IO ()
timerOwnerInstance world key serving =
  atomically (modifyTVar' (ftOwners (wTimer world)) (Map.adjust (\owner → owner {toInstances = serving : toInstances owner}) key))

-- | The owner is gone: the step no longer waits for it.
forgetTimerOwner ∷ World → Unique → IO ()
forgetTimerOwner world key = atomically $ do
  modifyTVar' (ftOwners (wTimer world)) (Map.delete key)
  modifyTVar' (ftInTurn (wTimer world)) (Set.delete key)

-- | The live registrations, oldest first.
liveList ∷ FakeTimer → STM [Registration]
liveList timer = filterM (readTVar . regLive) =<< readTVar (ftRegistrations timer)

-- | Fire every registration that is still live, once, as its timer would on expiry.
fireTimers ∷ World → IO ()
fireTimers world = do
  held ← readTVarIO (ftRegistrations (wTimer world))
  forM_ held $ \registration → do
    armed ← readTVarIO (regLive registration)
    if armed then atomically (writeTVar (regLive registration) False) >> regWake registration else pure ()

-- | How many registrations are live.
liveTimers ∷ World → IO Int
liveTimers world = length <$> atomically (liveList (wTimer world))

-- | The lengths, in microseconds, of the registrations that are still live, oldest first: what each armed
-- timer was asked to sleep for.
liveRegistrations ∷ World → IO [Int]
liveRegistrations world = map regMicros <$> atomically (liveList (wTimer world))

-- | Block until at least this many registrations are live: the owner has looked at its clock and
-- armed its timer.
awaitTimers ∷ World → Int → IO ()
awaitTimers world wanted = bounded loop
  where
    loop = do
      live ← liveTimers world
      if live >= wanted then pure () else yield >> loop

-- | How many registrations the owner has armed in all.
armedTimers ∷ World → IO Int
armedTimers world = readTVarIO (ftArmed (wTimer world))

-- | Block until the owner has armed at least this many registrations in all: it has looked at its clock
-- after a wake, or placed a deadline, and armed again.
awaitArmed ∷ World → Int → IO ()
awaitArmed world wanted = bounded loop
  where
    loop = do
      armed ← armedTimers world
      if armed >= wanted then pure () else yield >> loop

-- | Block, in STM, until the owner has ended this many segments in a wait.
awaitWaiting ∷ Fvm → Int → IO ()
awaitWaiting fvm wanted = bounded . atomically $ do
  reading ← scheduledDiagnostics (scheduledEndpoint (fvOwner fvm))
  if diagWaiting reading >= wanted then pure () else retry

-- The step ------------------------------------------------------------------------------------------

-- | ONE STEP TO THE NEXT REGISTRATION, for an example that waits for an update's effect and must never wake a later update
-- (#692). In one transaction: when the stop condition holds, claim nothing and answer 'True'; otherwise wait (retry, no sleep)
-- while an owner this step's predecessor woke is still in that turn, and while no registration is live; then claim the live
-- registration with the earliest deadline (the oldest among equals). Outside it, move the injected clock to exactly that deadline
-- (never back, never beyond) and wake it, once; answer 'False'.
--
-- THE INVARIANT: an owner is woken only after the turn the previous wake started has ended and the stop condition was decided
-- after it, in the transaction that claims the wake; the clock moves only there. What the step owns: the live flags it clears
-- (a claimed registration is never fired again) and the in-turn marks.
--
-- WHY. An owner arms its next elapsed point when it serves one, before the update runs, and syncs its timer only at the end of
-- the turn, reading the clock again: when the clock has passed the deadline by then it raises its own wake and registers
-- nothing ("Hetoimasia.Scripting.Lua.Scheduler.Timer"), so a clock moved while an owner is in a turn runs its next update with
-- nothing fired. A @print@ is in the sink when the call returns ("Hetoimasia.LuaEngine.Facade.Output"), inside the update and
-- so before the end of its turn: the registration that ends a turn is never visible without the lines the turn printed. One capability is no ordering: the Lua binding's calls are
-- safe foreign calls, which let another thread run, so this holds on any number of capabilities by coordination alone.
--
-- A TURN ENDS, for an owner whose turns are followed (a presentation VM), when it arms again, or when none of its admitted
-- instances is initializing or serving (nothing will arm). An owner the example parks on purpose in the middle of a turn (at a
-- gate an adapter hook waits at, at a fixture's wait: 'parkedWhile') does not hold the step while it is parked, so the example can
-- step the other VMs; any other owner in a turn does, and the bound around the pumping operation names it ('explainSteps').
--
-- THE RESIDUAL, accepted and stated: while one owner is parked, the steps for the others move the clock. When it is let go, its
-- own sync at the end of that turn can find its next point already passed and raise its own wake: ONE update of that owner that no
-- step woke. Only an owner the example itself parked and released can do this.
stepNext ∷ World → STM Bool → IO Bool
stepNext world stop = (== StepStopped) <$> stepWith True world stop

-- | What one step did.
data Stepped
  = -- | The stop condition held: nothing was claimed and the clock did not move.
    StepStopped
  | -- | A registration was claimed and woken.
    StepWoke
  | -- | Nothing was live, and the step was not asked to wait for a registration ('stepIfRegistered').
    StepNothingLive
  deriving (Eq, Show)

-- | 'stepNext' that does not wait for a registration to appear: for a drive that also grants logical ticks, whose presentation
-- VM may have nothing armed.
stepIfRegistered ∷ World → STM Bool → IO Stepped
stepIfRegistered = stepWith False

stepWith ∷ Bool → World → STM Bool → IO Stepped
stepWith waitForOne world stop = do
  let timer = wTimer world
  claimed ← atomically $ do
    stopped ← stop
    if stopped
      then pure (Left StepStopped)
      else do
        busy ← ownersInTurn timer
        unless (null busy) retry
        live ← liveList timer
        case sortOn regDeadline live of
          []
            | waitForOne → retry
            | otherwise → pure (Left StepNothingLive)
          next : _ → do
            writeTVar (regLive next) False
            owners ← readTVar (ftOwners timer)
            forM_ (regOwner next) $ \key →
              when (maybe False toTracked (Map.lookup key owners)) (modifyTVar' (ftInTurn timer) (Set.insert key))
            pure (Right next)
  case claimed of
    Left stepped → pure stepped
    Right next → do
      atomicModifyIORef' (wClock world) (\now → (max now (regDeadline next), ()))
      regWake next
      pure StepWoke

-- | The labels of the owners a step woke whose turn has not ended.
ownersInTurn ∷ FakeTimer → STM [Text]
ownersInTurn timer = do
  marked ← Set.toList <$> readTVar (ftInTurn timer)
  owners ← readTVar (ftOwners timer)
  fmap concat . forM marked $ \key → case Map.lookup key owners of
    Nothing → pure []
    Just owner → do
      serving ← or <$> sequence (toInstances owner)
      parked ← case (toThread owner, toParking owner) of
        (Just thread, Just (Parking held)) → Set.member thread <$> readTVar held
        _ → pure False
      pure [toLabel owner | serving, not parked]

-- | Step until the stop condition holds: one bound ('bounded') over the whole operation, not one per step.
stepUntil ∷ World → STM Bool → IO ()
stepUntil = stepUntilWithin bounded

-- | 'stepUntil' under this bound over the whole operation.
stepUntilWithin ∷ (IO () → IO ()) → World → STM Bool → IO ()
stepUntilWithin bound world stop = bound loop `onException` explainSteps world
  where
    loop = stepNext world stop >>= \stopped → unless stopped loop

-- | Wake the next registration, whenever it appears (after the turn the previous step started has ended), once.
stepOnce ∷ World → IO ()
stepOnce world = bounded (void (stepNext world (pure False))) `onException` explainSteps world

-- | ONE LOGICAL TICK, the gameplay VM's counterpart of 'stepNext': in one transaction, when the stop condition holds grant nothing
-- and answer 'True'; otherwise wait (retry) while a tick granted before has not completed (a task it woke still ready or
-- running, a script held at a fixture's wait included), then grant one. A logical update runs only at a granted tick, so the
-- update after the one the example waits for is never granted before the condition was decided after it.
tickNext ∷ Fvm → STM Bool → IO Bool
tickNext fvm stop = do
  let endpoint = scheduledEndpoint (fvOwner fvm)
  one ← either (\refused → assertFailure (show refused)) pure (durationFromNanoseconds RequirePositive 1)
  answer ← atomically $ do
    stopped ← stop
    if stopped
      then pure Nothing
      else do
        outstanding ← ticksOutstanding endpoint
        when (outstanding > 0) retry
        Just <$> grantScheduledStepSTM endpoint one
  case answer of
    Nothing → pure True
    Just GrantAccepted {} → pure False
    Just refused → assertFailure ("the tick was not granted: " <> show refused)

-- | Tick until the stop condition holds ('tickNext'): one bound over the whole operation.
tickUntil ∷ Fvm → STM Bool → IO ()
tickUntil fvm stop = bounded loop
  where
    loop = tickNext fvm stop >>= \stopped → unless stopped loop

-- | Drive a gameplay VM and the presentation VMs beside it together until the condition holds: each round one tick ('tickNext')
-- and then one step ('stepIfRegistered'), the condition decided before each; one bound over the whole operation.
tickAndStepUntil ∷ Fvm → World → STM Bool → IO ()
tickAndStepUntil fvm world stop = bounded loop `onException` explainSteps world
  where
    loop =
      tickNext fvm stop >>= \stopped → unless stopped $
        stepIfRegistered world stop >>= \case
          StepStopped → pure ()
          _ → loop

-- | What the step was waiting for, when a pumping operation did not end: the clock, the live registrations and the owners in a
-- turn.
explainSteps ∷ World → IO ()
explainSteps world = do
  let timer = wTimer world
  now ← readIORef (wClock world)
  (live, busy, owners) ← atomically ((,,) <$> liveList timer <*> ownersInTurn timer <*> readTVar (ftOwners timer))
  let name registration = maybe "no owner" (\key → maybe "a forgotten owner" (Text.unpack . toLabel) (Map.lookup key owners)) (regOwner registration)
  putStrLn
    ( "the step: clock " <> show now <> " ns; live registrations " <> show [(name r, regMicros r, regDeadline r) | r ← live]
        <> "; owners still in the turn a step started (the step waits for them to arm again) " <> show busy
    )

-- | Fire the live registrations until the condition holds. Firing is idempotent for the owner, which
-- looks at its clock at each wake, so how often it happens is not what an example depends on.
pumpUntil ∷ World → IO Bool → IO ()
pumpUntil world condition = bounded loop
  where
    loop = do
      done ← condition
      if done then pure () else fireTimers world >> yield >> loop

-- VMs ----------------------------------------------------------------------------------------------

-- | What an example chooses about a VM.
data VmShape = VmShape
  { shRole ∷ !Role
  , shTickNanoseconds ∷ !Word64
  -- ^ A gameplay VM's fixed tick duration.
  , shRoots ∷ ![Text]
  -- ^ The enabled content roots.
  , shGraphics ∷ !(Maybe GraphicsInjection)
  -- ^ The graphics a composition injects into the VM, if any (LFE-21).
  , shTakesWork ∷ !(STM Bool)
  -- ^ Whether the session still takes new work for this role, as the injected gate the facade's services read in their own transactions.
  , shInitialChunks ∷ ![Text]
  -- ^ Lua a VM runs before the facade's own chunk, which still sees the hidden namespace of bindings: how a fixture hands a script a
  -- host-made value.
  , shParking ∷ !(Maybe Parking)
  -- ^ Where the example's own hold points mark the owner threads they park ('parkedWhile'), for the step.
  , shTerrain ∷ !(Maybe (TerrainInjection, Unique))
  -- ^ The terrain a composition injects into the VM, if any (TRA-5), with the identity of the session it belongs to: the
  -- same for every VM of one session, so that both roles share a namespace and a second session does not.
  }

-- | A gameplay VM whose tick is a millisecond, enabling the session's root.
gameplayShape ∷ VmShape
gameplayShape = VmShape Gameplay 1000000 ["modules-test"] Nothing (pure True) [] Nothing Nothing

-- | A presentation VM enabling the session's root.
presentationShape ∷ VmShape
presentationShape = VmShape Presentation 0 ["modules-test"] Nothing (pure True) [] Nothing Nothing

-- | One VM: its owner, coordinator, facade and loader endpoint.
data Fvm = Fvm
  { fvOwner ∷ !ScheduledOwner
  , fvCoordinator ∷ !Coordinator
  , fvFacade ∷ !Facade
  , fvLoader ∷ !LoaderEndpoint
  , fvRole ∷ !Role
  , fvTimerOwner ∷ !Unique
  -- ^ The owner's key in the world's timer ('timerOwner').
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Supervision.Service Supervision.Required (unsafeComponent "test.luaengine.facade") (\_ → pure Unrecognized)

-- | Run a body over one VM of this shape: a coordinator over the session's pool, a data service, a facade
-- injected with the world's controlled endpoints, and an owner that carries it. The coordinator is
-- closed and the owner stopped however the body ends.
withFvm ∷ World → LuaRuntime → VmShape → (Fvm → IO a) → IO a
withFvm world runtime shape body =
  withFvmRefusing world runtime shape body `catch` \(RefusedFacade refused) → assertFailure ("the facade was refused: " <> show refused)

-- | What making a facade over this world's profile comes to, without an example's body: the refusal, or that a
-- VM of this shape was made and its owner started and stopped.
attemptFvm ∷ World → LuaRuntime → VmShape → IO (Either FacadeRefused ())
attemptFvm world runtime shape =
  (Right <$> withFvmRefusing world runtime shape (\_ → pure ())) `catch` \(RefusedFacade refused) → pure (Left refused)

-- | A facade the profile does not allow, as an exception only 'withFvm' and 'attemptFvm' ever see.
newtype RefusedFacade = RefusedFacade FacadeRefused
  deriving (Show)

instance Exception RefusedFacade

withFvmRefusing ∷ World → LuaRuntime → VmShape → (Fvm → IO a) → IO a
withFvmRefusing world runtime shape body = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests profile handles)
  phase ← newModulePhase
  tickRef ← newIORef (pure 0 ∷ IO Word64)
  timerKey ← timerOwner world ("facade-" <> roleText) (shParking shape) (shRole shape == Presentation)
  let moduleSpec =
        ModuleSpec
          { specRequests = requests
          , specInventory = ssInventory session
          , specPool = ssPool session
          , specResolve = inventoryResolver (ssInventory session) (shRoots shape)
          , specLogger = ssLogger session
          , specRole = roleText
          , specSlots = 4
          , specBootWaiters = 2
          , specPhase = Just phase
          }
  withModuleCoordinator moduleSpec $ \coordinator → do
    bank ← newByteBankFor profile
    service ← either (\refused → assertFailure ("the data service was refused: " <> show refused)) pure (dataService requests (ssInventory session) (ssPool session) bank)
    tickDuration ← case shRole shape of
      Gameplay → either (\refused → assertFailure (show refused)) (pure . Just) (durationFromNanoseconds RequirePositive (toInteger (shTickNanoseconds shape)))
      Presentation → pure Nothing
    let endpoints =
          FacadeEndpoints
            { endpointAdmission = readTVarIO (wAdmission world)
            , endpointFailure = \failure → do
                atomically (modifyTVar' (wFailures world) (<> [failure]))
                raising ← readIORef (wReportFails world)
                when raising (throwIO (userError "the report of the failure failed"))
            , endpointClock = scriptedSource (scriptedInstant <$> laggingDuration world)
            , endpointTick = readIORef (wTickOverride world) >>= maybe (join (readIORef tickRef)) pure
            }
        -- The injected session: a status an example sets, a counter of the quits and a log of the terminal latches.
        injectedSession =
          SessionEndpoints
            { endpointStatus = readTVar (wStatus world)
            , endpointQuit = atomically (modifyTVar' (wQuits world) (+ 1))
            , endpointTerminal = \context → do
                first ← atomically $ do
                  before ← readTVar (wTerminals world)
                  writeTVar (wTerminals world) (before <> [context])
                  pure (null before)
                failing ← readIORef (wTerminalFail world)
                when failing (throwIO (userError "the terminal latch failed"))
                pure first
            }
    -- The VM's leasing services over its one lending and lease scope, composed as a session composes them.
    sessionKey ← maybe newUnique (pure . snd) (shTerrain shape)
    VmServices graphics terrain scope ←
      composeVmServices profile (shRole shape) requests (shTakesWork shape) sessionKey (shGraphics shape) (fst <$> shTerrain shape)
    facade ←
      newFacade
        FacadeSpec
          { fsRole = shRole shape
          , fsRequests = requests
          , fsCoordinator = coordinator
          , fsData = service
          , fsInventory = ssInventory session
          , fsOutput = wOutput world
          , fsEndpoints = endpoints
          , fsSession = injectedSession
          , fsPhase = phase
          , fsRoots = shRoots shape
          , fsIds = wIds world
          , fsTickDuration = tickDuration
          , fsGraphics = graphics
          , fsTerrain = terrain
          }
        >>= either (throwIO . RefusedFacade) pure
    let base = (vmProfileConfig LibraryProfileM1) {vmOwnerName = "facade-" <> roleText}
    config ← either (\refused → assertFailure ("the facade was not installed: " <> show refused)) pure (installFacade facade [] [] base)
    let withChunks =
          config
            { vmInitialChunks =
                [(chunkName ("harness chunk " <> Text.pack (show index)), Text.encodeUtf8 source) | (index, source) ← zip [(0 ∷ Int) ..] (shInitialChunks shape)]
                  <> vmInitialChunks config
            }
    let grant = RequestGrant (facadeRequestEndpoints facade) 64 (if shRole shape == Gameplay then SettleAtAssignedTick Nothing else SettleOnArrival)
        instances = facadeInstanceConfig facade (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceTickDuration = tickDuration})
        spec =
          (scheduledSpec withChunks requiredPolicy bounds)
            { scheduledInstances = Just instances
            , scheduledRequestHandles = Just handles
            , scheduledLending = (\(lending, _, _) → lending) <$> scope
            , scheduledLeases = (\(_, leases, _) → leases) <$> scope
            , -- the collection holds every live instance (up to eight here) at the scope's lease capacity
              scheduledMemberLimit = maximum (defaultMemberLimit : [8 * capacity | Just (_, _, capacity) ← [scope]])
            , scheduledRequests = Just grant
            , scheduledLoader = Just (coordinatorPlan coordinator)
            , scheduledClock = scriptedSource (scriptedInstant <$> clockDuration world)
            , scheduledTimer = timerBackend world (Just timerKey)
            , scheduledRefusedWait = facadeRefusedWait facade
            }
    started ← startScheduledOwner runtime spec
    owner ← case started of
      ScheduledStarted found → pure found
      ScheduledUnavailable failure → assertFailure ("the owner was unavailable: " <> show failure)
      ScheduledRejected → assertFailure "the owner was rejected"
      ScheduledEnded → assertFailure "the owner ended"
    endpoint ← maybe (assertFailure "the owner has no loader endpoint") pure (scheduledLoaderEndpoint owner)
    attachLoader coordinator endpoint
    writeIORef tickRef (atomically (scheduledTick (scheduledEndpoint owner)))
    -- The owner stops before the coordinator and the output close: a hook that runs while it retires
    -- (a @shutdown@ that prints) still finds both.
    body (Fvm owner coordinator facade endpoint (shRole shape) timerKey) `finally` (retireAndAwait (wControl world) owner >> forgetTimerOwner world timerKey)
  where
    session = wSession world
    profile = wProfile world
    roleText = case shRole shape of
      Gameplay → "gameplay"
      Presentation → "presentation"
    bounds =
      SchedulerBounds
        { boundActiveTasks = 16
        , boundQueuedAdmissions = 16
        , boundRetainedResults = 32
        , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
        , boundOutstandingGrants = 4
        , boundControlRequests = 8
        , boundServiceBudget = Nothing
        }

-- | Ask the owner to retire, and wait, under supervision, until it is no longer live.
retireAndAwait ∷ RuntimeControl → ScheduledOwner → IO ()
retireAndAwait control owner = do
  retireScheduled owner
  awaitSupervised control $
    scheduledStatus owner >>= \case
      WorkerLive → retry
      _ → pure ()

-- | The logical tick the owner has reached.
ownerTick ∷ Fvm → IO Word64
ownerTick fvm = atomically (scheduledTick (scheduledEndpoint (fvOwner fvm)))

-- Instances ----------------------------------------------------------------------------------------

-- | An instance admitted to a VM.
data Spawned = Spawned
  { spId ∷ !Text
  -- ^ The facade's identity for it (@instance_id@).
  , spInstance ∷ !InstanceId
  , spTicket ∷ !InstanceTicket
  , spVm ∷ !Fvm
  }

-- | Boot the entry module, declare an instance of this content and admit its behavior, then wait for it
-- to be serving. The module must evaluate; an instance that fails before it serves is found by
-- 'admitOnly' and 'settledOf'.
spawn ∷ World → Fvm → Text → ByteString → IO Spawned
spawn world fvm content entry = do
  spawned ← admitOnly world fvm content entry
  awaitActive spawned
  pure spawned

-- | The same, without waiting for the instance to serve.
admitOnly ∷ World → Fvm → Text → ByteString → IO Spawned
admitOnly world fvm content entry = admitWith world fvm content entry (\_ _ → pure ())

-- | The same, doing this between declaring the instance and admitting it.
admitWith ∷ World → Fvm → Text → ByteString → (Facade → Declared → IO ()) → IO Spawned
admitWith world fvm content entry between = do
  let key = key' (wSession world) entry
  booted ← bootModule (fvCoordinator fvm) key
  ticket ← either (\refused → assertFailure ("the boot load was refused: " <> show refused)) pure booted
  outcome ← atomically (awaitBoot ticket)
  case outcome of
    BootReady → pure ()
    other → assertFailure ("the entry module did not evaluate: " <> show other)
  declared ← declareInstance (fvFacade fvm) content >>= either (\refused → assertFailure ("declaring the instance was refused: " <> show refused)) pure
  between (fvFacade fvm) declared
  let request = behaviorRequest (fvRole fvm) (moduleIdentity key) (Text.decodeUtf8 entry) (declaredFacade declared) (Just (declaredId declared)) OrdinaryClass
  admitted ← admitBehaviorInstance (scheduledEndpoint (fvOwner fvm)) request
  case admitted of
    InstanceAccepted identity instanceTicket → do
      timerOwnerInstance world (fvTimerOwner fvm) $
        maybe False ((`elem` [Initializing, Active]) . snapshotPhase) <$> inspectInstance (scheduledEndpoint (fvOwner fvm)) identity
      pure (Spawned (declaredId declared) identity instanceTicket fvm)
    other → assertFailure ("expected the instance accepted, found " <> take 100 (show other))

-- | Boot the module at this path in the VM (the loader evaluates it with no waiter and no tick) and wait
-- for how it came out.
bootPath ∷ World → Fvm → ByteString → IO BootOutcome
bootPath world fvm path = do
  booted ← bootModule (fvCoordinator fvm) (key' (wSession world) path)
  ticket ← either (\refused → assertFailure ("the boot load was refused: " <> show refused)) pure booted
  atomically (awaitBoot ticket)

-- | Block until the instance is serving; an instance that ends first fails the example, with how it ended.
awaitActive ∷ Spawned → IO ()
awaitActive spawned = do
  phase ← atomically $
    inspectInstance (scheduledEndpoint (fvOwner (spVm spawned))) (spInstance spawned) >>= \case
      Just snapshot
        | snapshotPhase snapshot == Active → pure Active
        | isTerminal (snapshotPhase snapshot) → pure (snapshotPhase snapshot)
      _ → retry
  when (phase /= Active) $ do
    settlement ← settledOf spawned
    assertFailure ("the instance ended before it served: " <> take 3000 (show (resultOutcome settlement)))

-- | The phase the instance is in now, if the owner still holds it.
phaseOf ∷ Spawned → IO (Maybe InstancePhase)
phaseOf = atomically . phaseOfSTM

-- | 'phaseOf' in a transaction, for a stop condition.
phaseOfSTM ∷ Spawned → STM (Maybe InstancePhase)
phaseOfSTM spawned = fmap snapshotPhase <$> inspectInstance (scheduledEndpoint (fvOwner (spVm spawned))) (spInstance spawned)

-- | The settlement of an instance, waiting for it.
settledOf ∷ Spawned → IO InstanceSettlement
settledOf = waitInstance . spTicket

-- | The failure an instance settled with, if it failed.
settledFailure ∷ Spawned → IO (Maybe InstanceFailure)
settledFailure spawned = do
  settlement ← settledOf spawned
  pure $ case resultOutcome settlement of
    InstanceFailed failure → Just failure
    _ → Nothing

-- | The endpoint and attributed text of a required request's failure.
requestFailureOf ∷ Maybe InstanceFailure → Maybe (Text, Text)
requestFailureOf failure = case fmap failureError failure of
  Just (ErrorRequest endpoint why) → Just (endpoint, why)
  _ → Nothing

-- | Ask the instance to stop.
stopSpawned ∷ Spawned → IO ()
stopSpawned spawned =
  requestInstanceControl (scheduledEndpoint (fvOwner (spVm spawned))) (spInstance spawned) InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 100 (show other))

-- | Grant this many logical ticks, one at a time, waiting for each to complete.
tickBy ∷ RuntimeControl → Fvm → Int → IO ()
tickBy control fvm count = replicateM_ count $ do
  one ← either (\refused → assertFailure (show refused)) pure (durationFromNanoseconds RequirePositive 1)
  _ ← grantScheduledStep (scheduledEndpoint (fvOwner fvm)) one
  void (awaitTicksComplete control (fvOwner fvm))

-- | Grant one logical tick without waiting for it to complete.
grantTick ∷ Fvm → IO ()
grantTick fvm = do
  one ← either (\refused → assertFailure (show refused)) pure (durationFromNanoseconds RequirePositive 1)
  void (grantScheduledStep (scheduledEndpoint (fvOwner fvm)) one)

-- | Wait, under supervision, for the granted ticks to complete.
awaitTickDone ∷ RuntimeControl → Fvm → IO ()
awaitTickDone control fvm = bounded (void (awaitTicksComplete control (fvOwner fvm)))

-- | Wait, under supervision, for the owner to end.
awaitEnded ∷ RuntimeControl → Fvm → IO WorkerStatus
awaitEnded control fvm =
  bounded . awaitSupervised control $
    scheduledStatus (fvOwner fvm) >>= \case
      WorkerLive → retry
      status → pure status

-- Authoring ----------------------------------------------------------------------------------------

-- | Lua source from lines.
luaMain ∷ [Text] → ByteString
luaMain = Text.encodeUtf8 . Text.unlines

-- | Lua that defines @show(v)@ (a value as one line, tables with sorted keys) and @try(label, f, ...)@, which
-- calls @f@ under @pcall@ and prints @label => ok ; result...@ on one line. Examples print what they saw, and
-- assert on those lines.
tryPrelude ∷ [Text]
tryPrelude =
  [ "local function show(v, depth)"
  , "  depth = depth or 0"
  , "  local t = type(v)"
  , "  if t == 'string' then return v end"
  , "  if t == 'number' then return (math.type(v) == 'integer' and tostring(v)) or ('f' .. tostring(v)) end"
  , "  if t ~= 'table' then return (tostring(v):gsub('^(%a+): .*', '<%1>')) end"
  , "  if depth >= 2 then return '<table>' end"
  , "  local entries = {}"
  , "  for k, x in pairs(v) do entries[#entries + 1] = {tostring(k), x} end"
  , "  table.sort(entries, function(a, b) return a[1] < b[1] end)"
  , "  local out = {}"
  , "  for _, entry in ipairs(entries) do out[#out + 1] = entry[1] .. '=' .. show(entry[2], depth + 1) end"
  , "  return '{' .. table.concat(out, ',') .. '}'"
  , "end"
  , "local function try(label, f, ...)"
  , "  local results = table.pack(pcall(f, ...))"
  , "  local out = {}"
  , "  for i = 1, results.n do out[#out + 1] = show(results[i]) end"
  , "  print(label .. ' => ' .. table.concat(out, ' ; '))"
  , "end"
  ]

-- | Lua that defines @dump(v)@: a value as one line with every table's keys sorted and nested without a depth
-- limit, strings in double quotes. The expectations of the status record are written against it.
dumpPrelude ∷ [Text]
dumpPrelude =
  [ "local function dump(v)"
  , "  if type(v) == 'string' then return '\"' .. (v:gsub('\\n', '\\\\n')) .. '\"' end"
  , "  if type(v) ~= 'table' then return tostring(v) end"
  , "  local keys = {}"
  , "  for k in pairs(v) do keys[#keys + 1] = k end"
  , "  table.sort(keys)"
  , "  local parts = {}"
  , "  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. dump(v[k]) end"
  , "  return '{' .. table.concat(parts, ',') .. '}'"
  , "end"
  ]

-- | A behavior an example writes as pieces of Lua: what the module does at its top level, the bodies of
-- its hooks (the update's and shutdown's @api@ is @self.api@), and the cadence it asks for.
data Script = Script
  { scPrelude ∷ ![Text]
  , scInit ∷ ![Text]
  , scUpdate ∷ ![Text]
  , scShutdown ∷ ![Text]
  , scHasInit ∷ !Bool
  , scEverySeconds ∷ !Text
  -- ^ The presentation cadence, in seconds, written as Lua.
  }

-- | A script that does nothing.
script ∷ Script
script = Script [] [] [] [] True "1"

-- | The module: both roles' behaviors carry the same hooks, so one file serves a gameplay or a
-- presentation VM.
scriptSource ∷ Script → ByteString
scriptSource found =
  luaMain $
    tryPrelude
      <> scPrelude found
      <> ["local function behavior(cadence)"]
      <> ["  local b = cadence"]
      <> (if scHasInit found then ["  b.init = function(self, api)"] <> indent (scInit found) <> ["  end"] else [])
      <> ["  b.update = function(self, dt)", "    local api = self.api"]
      <> indent (indent (scUpdate found))
      <> ["  end"]
      <> ["  b.shutdown = function(self, reason)", "    local api = self.api"]
      <> indent (indent (scShutdown found))
      <> ["  end", "  return b", "end"]
      <> ["return { gameplay = behavior({every_ticks = 1}), presentation = behavior({every_seconds = " <> scEverySeconds found <> "}) }"]
  where
    indent = map ("  " <>)

-- | The path the examples' behavior is written at.
mainPath ∷ ByteString
mainPath = "lua/main.lua"

-- | A world holding the script as the entry module, a VM of this role, and one instance of the content
-- serving it.
withOne ∷ Role → Profile → Script → (World → RuntimeControl → Fvm → Spawned → IO a) → IO a
withOne role profile found = withOneIn role profile found []

-- | The same with more files in the content tree.
withOneIn ∷ Role → Profile → Script → [(FilePath, ByteString)] → (World → RuntimeControl → Fvm → Spawned → IO a) → IO a
withOneIn role profile found more body =
  withWorld profile (Layout (("lua/main.lua", scriptSource found) : more)) $ \world control runtime →
    withFvm world runtime (if role == Gameplay then gameplayShape else presentationShape) $ \fvm → do
      spawned ← spawn world fvm "modules-test" mainPath
      body world control fvm spawned

-- | One presentation or gameplay instance over a VM with these graphics injected.
withOneGraphics ∷ GraphicsInjection → Role → Script → [(FilePath, ByteString)] → (World → RuntimeControl → Fvm → Spawned → IO a) → IO a
withOneGraphics injection role found more body =
  withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource found) : more)) $ \world control runtime →
    withFvm world runtime ((if role == Gameplay then gameplayShape else presentationShape) {shGraphics = Just injection}) $ \fvm → do
      spawned ← spawn world fvm "modules-test" mainPath
      body world control fvm spawned
