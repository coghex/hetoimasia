-- | What the runner's examples share: real script files in a directory of their own, an injected
-- clock and a fake timer, sinks that record, a stop request an example sets, test bindings the
-- scripts record and block through, and the coordination the examples use instead of sleeping.
--
-- Every example runs real Lua on a real supervised scheduled owner, started by the runner under
-- 'withBoundary'. The runner waits on the application thread, which owns the supervision control,
-- so an example never runs it on another thread; what has to happen while it runs (a stop request,
-- the release of a gate, a timer fired by hand) is done by a helper thread that waits for the
-- state it needs and never for a delay.
module Test.LuaRuntime.Runner.Support
  ( -- * The fixture
    RFixture (..)
  , newRFixture
  , recorded
  , outLines
  , errLines
  , setStop
    -- * Scripts
  , lua
  , withScripts
  , scriptAt
  , noWait
    -- * Running
  , config
  , tickConfig
  , driveTicks
  , run
  , runTick
  , runWith
  , internals
  , internalsWithTick
  , tickSource
  , deliverTick
  , admittedOf
  , awaitSnapshots
  , awaitIdle
  , awaitRetiring
  , withCapturedStreams
  , outstanding
  , expectRan
  , expectRefused
    -- * Helpers that act while a run is in progress
  , alongside
  , awaitCount
  , awaitOut
  , awaitRecorded
  , awaitLive
  , liveTimers
  , fireLive
  , fireEvery
  , tickClock
  , regCount
  , liveCount
  , gatedOn
  , gatedErrorsOn
  , awaitGate
  , openGate
    -- * Reading reports
  , instancesOf
  , endOf
  , statusOf
  , tidsOf
  , failureOf
  , loadFailureOf
    -- * Time
  , ns
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (finally, throwIO)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, scriptedInstant, scriptedSource)
import Hetoimasia.Foundation.Worker (GroupStatus (statusOutstanding))
import Hetoimasia.Runtime.Supervision (RuntimeControl, workerGroupStatus)
import Hetoimasia.Scripting.Lua.Instance (Delivery (DeliveryClosed), EventSource (EventSource), InstanceId, InstanceSnapshot, InstanceTicket, deliverEvent, inspectInstances)
import Hetoimasia.Scripting.Lua.Scheduled (ScheduledEndpoint, ticksOutstanding)
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryOperation), FaultOperation (LoadModule))
import Hetoimasia.Scripting.Lua.Registration (Namespace, WaitKind (WaitElapsed, WaitLogical), namespace, stateOperation, waitOperation, yieldOperation)
import Hetoimasia.Scripting.Lua.Runner
import Hetoimasia.Scripting.Lua.Runner.Internal (RunnerInternals (..), noInternals, quiet, runScriptsWith)
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger, SRecord, SText), Value (VInteger, VRecord, VText))
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (createDirectory, getTemporaryDirectory, removeDirectoryRecursive, removeFile)
import System.IO (hClose, hFlush, openBinaryTempFile, stderr, stdout)
import System.FilePath ((</>))
import Test.LuaRuntime.Scheduled.Support (Clock (Clock), SFixture (..), awaitEntered, blockOn, newSFixture, releaseGate)
import Test.LuaRuntime.Scheduler.Support (FakeTimer (..), Reg (regLive), allRegs, fireReg, nanoseconds)
import Test.LuaRuntime.Support (alongsideOpening, applicationBoundaryFault, Broken (Broken), failExample, Gated (..), quietLogger)

-- The fixture ------------------------------------------------------------------

-- | What an example observes and shares.
data RFixture = RFixture
  { rfBase ∷ !SFixture
    -- ^ The injected clock, the fake timer, the gates and the log of what bindings recorded.
  , rfOut ∷ !(IORef [Text])
  , rfErr ∷ !(IORef [Text])
  , rfStop ∷ !(TVar Bool)
  , rfCounter ∷ !(IORef Int)
  , rfLines ∷ !(IORef [(Text, Text)])
    -- ^ Every line either sink was handed, in the order it was handed, with the sink's name.
  , rfAdmitted ∷ !(MVar (ScheduledEndpoint, [(InstanceId, InstanceTicket)]))
    -- ^ The owner's endpoint and the instances, once the run has admitted them.
  }

instance Gated RFixture where
  openAllGates = openAllGates . rfBase

newRFixture ∷ IO RFixture
newRFixture = RFixture <$> newSFixture <*> newIORef [] <*> newIORef [] <*> newTVarIO False <*> newIORef 0 <*> newIORef [] <*> newEmptyMVar

-- | What the scripts recorded through @fx.record@, oldest first.
recorded ∷ RFixture → IO [Text]
recorded fixture = reverse <$> readIORef (sfLog (rfBase fixture))

-- | What the output sink was handed, oldest first.
outLines ∷ RFixture → IO [Text]
outLines fixture = reverse <$> readIORef (rfOut fixture)

-- | What the error sink was handed, oldest first.
errLines ∷ RFixture → IO [Text]
errLines fixture = reverse <$> readIORef (rfErr fixture)

setStop ∷ RFixture → Bool → IO ()
setStop fixture = atomically . writeTVar (rfStop fixture)

-- | The test bindings every script of an example can call: @fx.record(text)@ notes a line,
-- @fx.block(name)@ waits at a gate the example opens, after saying it was reached, @fx.fail(kind)@
-- raises a failure of the host, @fx.bump()@ counts and answers the count, @fx.stop()@ sets the
-- stop request, and @fx.yield()@, @fx.wait_ticks(n)@ and @fx.wait_ns(n)@ suspend the hook.
fxNamespace ∷ RFixture → Namespace
fxNamespace fixture =
  namespace
    "fx"
    [ stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → atomicModifyIORef' (sfLog (rfBase fixture)) (\held → (text : held, ()))
          _ → pure ()
        pure []
    , stateOperation "block" [SText] [] $ \arguments → do
        case arguments of
          [VText name] → blockOn (rfBase fixture) name
          _ → pure ()
        pure []
    , stateOperation "fail" [SText] [] $ \arguments → do
        case arguments of
          [VText "boundary"] → throwIO applicationBoundaryFault
          [VText kind] → throwIO (Broken kind)
          _ → pure ()
        pure []
    , stateOperation "fail_load" [] [] $ \_ →
        -- A failure of the application's own making, shaped as the host's fault of loading a module.
        throwIO applicationBoundaryFault {boundaryOperation = LoadModule}
    , stateOperation "bump" [] [SInteger] $ \_ →
        (\count → [VInteger (fromIntegral count)]) <$> atomicModifyIORef' (rfCounter fixture) (\held → (held + 1, held + 1))
    , stateOperation "stop" [] [] $ \_ → setStop fixture True >> pure []
    , -- A yield, and waits for ticks and for time, which suspend the instance's hook the way a task's
      -- own code does. The runner itself grants no script such a binding.
      yieldOperation "yield"
    , waitOperation "wait_ticks" WaitLogical [SInteger]
    , waitOperation "wait_ns" WaitElapsed [SInteger]
    ]

-- Scripts ----------------------------------------------------------------------

-- | Lua source from lines.
lua ∷ [Text] → ByteString
lua = Text.encodeUtf8 . Text.unlines

-- | Run an example with a directory of its own holding these files, by name, and the paths they were
-- written to; the directory is removed afterwards.
withScripts ∷ [(FilePath, ByteString)] → ([FilePath] → IO a) → IO a
withScripts files body = do
  base ← getTemporaryDirectory
  started ← getPOSIXTime
  let directory = base </> ("lua-runner-" <> show (round (started * 1000000000) ∷ Integer))
  createDirectory directory
  (mapM (\(name, bytes) → let path = directory </> name in ByteString.writeFile path bytes >> pure path) files >>= body)
    `finally` removeDirectoryRecursive directory

-- | A path in the directory, for a file an example does not write.
scriptAt ∷ [FilePath] → Int → FilePath
scriptAt paths index = paths !! index

-- | No interval, no name.
noWait ∷ FilePath → Script
noWait = script

-- Running ----------------------------------------------------------------------

-- | A configuration over these scripts: the fixture's clock, timer, sinks and stop request, no limit.
config ∷ RFixture → [Script] → RunnerConfig
config fixture scripts =
  (runnerConfig "vm" scripts quietLogger (sinkInto "out" (rfOut fixture)) (sinkInto "err" (rfErr fixture)))
    { runnerStop = readTVar (rfStop fixture)
    , runnerClock = let Clock ref = sfClock (rfBase fixture) in scriptedSource (scriptedInstant . nanoseconds <$> readIORef ref)
    , runnerTimer = ftBackend (sfTimer (rfBase fixture))
    }
  where
    sinkInto name ref line = atomicModifyIORef' ref (\held → (line : held, ())) >> noteLine name line
    noteLine name line = atomicModifyIORef' (rfLines fixture) (\held → ((name, line) : held, ()))

-- | A tick VM over these scripts: ticks of this many nanoseconds, a tick limit if there is one.
tickConfig ∷ RFixture → Word64 → Maybe Integer → [Script] → RunnerConfig
tickConfig fixture period limit scripts = (config fixture scripts) {runnerTick = Just (ns period), runnerTickLimit = limit}

-- | Make this many ticks due, one at a time, as the driver arms its timer for each: the clock is moved a
-- tick's duration and the timer's registration fired by hand, and the next tick is waited for to have
-- been armed. The run, on the example's thread, ends after the last, so it is not waited for here.
driveTicks ∷ RFixture → Word64 → Int → IO ()
driveTicks fixture period count = go count
  where
    go 0 = pure ()
    go remaining = do
      awaitLive fixture 1
      before ← regCount fixture
      tickClock fixture period
      fireLive fixture
      when (remaining > 1) (awaitCount (regCount fixture) (before + 1))
      go (remaining - 1 ∷ Int)

-- | The seams every example has: the fixture's bindings and no event source.
internals ∷ RFixture → RunnerInternals
internals fixture =
  noInternals
    { internalNamespaces = [fxNamespace fixture]
    , internalAdmitted = \endpoint admitted → void (tryPutMVar (rfAdmitted fixture) (endpoint, admitted))
    }

-- | The seams with a @tick@ event source every instance may connect to, for the examples that need
-- a callback.
internalsWithTick ∷ RFixture → RunnerInternals
internalsWithTick fixture = (internals fixture) {internalSources = [tickSource], internalGrants = ["tick"]}

tickSource ∷ EventSource
tickSource = EventSource "tick" (SRecord [("n", SInteger)])

-- | Deliver a @tick@ event to an instance, once the run has admitted it.
deliverTick ∷ RFixture → Int → Int → IO Delivery
deliverTick fixture index n = do
  (endpoint, admitted) ← readMVar (rfAdmitted fixture)
  deliverEvent endpoint (fst (admitted !! index)) "tick" (VRecord [("n", VInteger (fromIntegral n))])

-- | The owner's endpoint and the instances, waiting for the run to have admitted them.
admittedOf ∷ RFixture → IO (ScheduledEndpoint, [(InstanceId, InstanceTicket)])
admittedOf = readMVar . rfAdmitted

-- | Wait, in STM, until the owner's instances read as these snapshots say.
awaitSnapshots ∷ RFixture → ([InstanceSnapshot] → Bool) → IO ()
awaitSnapshots fixture ok = do
  (endpoint, _) ← admittedOf fixture
  atomically (inspectInstances endpoint >>= \snapshots → if ok snapshots then pure () else retry)

-- | Wait, in STM, until no grant is outstanding and the runner's own reading of the owner's instances says
-- the owner has nothing it must do: the state a tick's boundary is reached in.
awaitIdle ∷ RFixture → IO ()
awaitIdle fixture = do
  (endpoint, _) ← admittedOf fixture
  atomically $ do
    outstanding' ← ticksOutstanding endpoint
    snapshots ← inspectInstances endpoint
    when (outstanding' /= 0 || not (quiet True snapshots)) retry

-- | Wait until the run has asked its owner to retire, which an example sees from the owner no longer
-- taking events: the instance at this index is told a @tick@ it has no connection for until the
-- answer is that the owner is closing. Yielding to the other threads between asks, never sleeping.
awaitRetiring ∷ RFixture → Int → IO ()
awaitRetiring fixture index =
  deliverTick fixture index 0 >>= \case
    DeliveryClosed → pure ()
    _ → yield >> awaitRetiring fixture index

-- | Run an action with the process's C standard output and error redirected to files of their own,
-- and answer what was written to each. Lua's own @print@ and @warn@ write there.
withCapturedStreams ∷ IO a → IO (a, ByteString, ByteString)
withCapturedStreams action = do
  directory ← getTemporaryDirectory
  hFlush stdout
  hFlush stderr
  savedOut ← hDuplicate stdout
  savedErr ← hDuplicate stderr
  (pathOut, handleOut) ← openBinaryTempFile directory "runner-stdout"
  (pathErr, handleErr) ← openBinaryTempFile directory "runner-stderr"
  hDuplicateTo handleOut stdout
  hDuplicateTo handleErr stderr
  let restore = do
        hFlush stdout
        hFlush stderr
        hDuplicateTo savedOut stdout
        hDuplicateTo savedErr stderr
  result ← action `finally` restore
  hClose handleOut
  hClose handleErr
  written ← (,) <$> ByteString.readFile pathOut <*> ByteString.readFile pathErr
  removeFile pathOut
  removeFile pathErr
  pure (result, fst written, snd written)

-- | How many workers the supervision boundary has outstanding.
outstanding ∷ RuntimeControl → IO Int
outstanding control = length . statusOutstanding <$> atomically (workerGroupStatus control)

-- | Run through the public runner, with the fixture's bindings.
run ∷ RFixture → LuaRuntime → RunnerConfig → IO RunOutcome
run fixture = runScriptsWith (internals fixture)

-- | Run with the fixture's bindings and its @tick@ event source.
runTick ∷ RFixture → LuaRuntime → RunnerConfig → IO RunOutcome
runTick fixture = runScriptsWith (internalsWithTick fixture)

-- | Run with these seams.
runWith ∷ RunnerInternals → LuaRuntime → RunnerConfig → IO RunOutcome
runWith = runScriptsWith

expectRan ∷ RunOutcome → IO RunReport
expectRan = \case
  Ran report → pure report
  Refused refusal → failExample ("expected a run, found a refusal: " <> show refusal)

expectRefused ∷ RunOutcome → IO [UsageViolation]
expectRefused = \case
  Refused (UsageRefusal violations) → pure (foldr (:) [] violations)
  Ran report → failExample ("expected a refusal, found a run: " <> show report)

-- Acting while a run is in progress -------------------------------------------

-- | 'alongsideOpening' with the fixture's gates: the helper is stopped when the run is over, and a
-- helper that fails opens them and is what the example fails with.
alongside ∷ RFixture → IO () → IO a → IO a
alongside fixture = alongsideOpening [openAllGates fixture]

-- | Wait until a counter of the example's reaches this many, yielding to the other threads and
-- never sleeping.
awaitCount ∷ IO Int → Int → IO ()
awaitCount counter wanted = do
  held ← counter
  when (held < wanted) (yield >> awaitCount counter wanted)

-- | Wait until the output sink has been handed this many lines.
awaitOut ∷ RFixture → Int → IO ()
awaitOut fixture wanted = awaitCount (length <$> outLines fixture) wanted

-- | Wait until the scripts have recorded this many lines.
awaitRecorded ∷ RFixture → Int → IO ()
awaitRecorded fixture wanted = awaitCount (length <$> recorded fixture) wanted

-- | Wait until the fake timer holds this many live registrations.
awaitLive ∷ RFixture → Int → IO ()
awaitLive fixture wanted = awaitCount (length <$> liveTimers fixture) wanted

-- | The fake timer's registrations that are armed and neither cancelled nor fired.
liveTimers ∷ RFixture → IO [Reg]
liveTimers fixture = do
  regs ← allRegs (sfTimer (rfBase fixture))
  filterM' (readIORef . regLive) regs
  where
    filterM' keep = fmap concat . mapM (\item → (\wanted → [item | wanted]) <$> keep item)

-- | How many registrations are armed and neither cancelled nor fired.
liveCount ∷ RFixture → IO Int
liveCount fixture = length <$> liveTimers fixture

-- | How many registrations the fake timer has ever been asked for.
regCount ∷ RFixture → IO Int
regCount fixture = length <$> allRegs (sfTimer (rfBase fixture))

-- | A configuration whose output sink blocks at the gate of this name, once it has been handed
-- this line: the run's own thread is held in its write, which is how an example makes several things
-- ready at the instant the run next waits.
gatedOn ∷ RFixture → Text → Text → RunnerConfig → RunnerConfig
gatedOn fixture line name configuration =
  configuration
    { runnerOutput = \written → do
        runnerOutput configuration written
        when (written == line) (blockOn (rfBase fixture) name)
    }

-- | A configuration whose error sink blocks at the gate of this name when it is handed a line that contains
-- this text: the run's own thread is held while it writes a report.
gatedErrorsOn ∷ RFixture → Text → Text → RunnerConfig → RunnerConfig
gatedErrorsOn fixture needle name configuration =
  configuration
    { runnerErrors = \written → do
        runnerErrors configuration written
        when (needle `Text.isInfixOf` written) (blockOn (rfBase fixture) name)
    }

-- | Wait until a binding or a sink has reached this gate.
awaitGate ∷ RFixture → Text → IO ()
awaitGate fixture = awaitEntered (rfBase fixture)

-- | Let what waits at this gate go on.
openGate ∷ RFixture → Text → IO ()
openGate fixture = releaseGate (rfBase fixture)

-- | Fire every live registration, as the timer would on expiry.
fireLive ∷ RFixture → IO ()
fireLive fixture = liveTimers fixture >>= mapM_ fireReg

-- | Fire every registration the fake timer was ever given, live or not, as a timer that was cancelled too
-- late would.
fireEvery ∷ RFixture → IO ()
fireEvery fixture = allRegs (sfTimer (rfBase fixture)) >>= mapM_ fireReg

-- | Move the injected clock.
tickClock ∷ RFixture → Word64 → IO ()
tickClock fixture n = let Clock ref = sfClock (rfBase fixture) in atomicModifyIORef' ref (\held → (held + n, ()))

-- Reading reports --------------------------------------------------------------

instancesOf ∷ RunReport → [InstanceReport]
instancesOf = reportInstances

endOf ∷ InstanceReport → InstanceEnd
endOf = instanceEnd

statusOf ∷ RunReport → RunStatus
statusOf = reportStatus

tidsOf ∷ RunReport → [InstanceId]
tidsOf = map instanceTid . reportInstances

failureOf ∷ InstanceReport → Maybe FailureReport
failureOf report = case instanceEnd report of
  EndFailed failure → Just failure
  _ → Nothing

loadFailureOf ∷ RunReport → Maybe LoadFailure
loadFailureOf = reportLoadFailure

-- Time ----------------------------------------------------------------------------

-- | A duration of this many nanoseconds.
ns ∷ Word64 → Duration
ns = nanoseconds
