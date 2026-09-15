-- | Examples for the window host and its supervised owner loop, over the test
-- seam.
--
-- Each example runs a whole application through
-- 'Hetoimasia.Runtime.GLFW.runWindowApplication' on a thread the seam treats as
-- the process main thread, with a host built over a seam session: the turn
-- order, budgets, idle waits, close-request surfacing, quiescence, and shutdown
-- order are the production code, and nothing initializes GLFW. Native events
-- are scripted inside the seam's poll and wait, and close requests are queued
-- for them with the private 'seamQueueEvents'.
--
-- Threads are coordinated with 'MVar's, STM, and 'threadStatus', never with a
-- sleep; a seam wait that must block blocks on a transaction.
module Test.GLFW.Host (spec) where

import Control.Concurrent (ThreadId, forkIO, forkOS, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (forM, join, replicateM, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Log (Component, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata, unsafeComponent)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Worker (StopToken, WorkerDefinition, awaitStopRequest, workerDefinition)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Command
import qualified Hetoimasia.GLFW.Input as Input
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Internal.Seam
  ( MonitorTopology (..)
  , NativeCall (..)
  , Seam
  , SeamMonitorEvent (MonitorDetached)
  , SeamScript (..)
  , WindowEvent (CloseRequested)
  , asProcessMainThread
  , defaultScript
  , designateProcessMainThread
  , newSeam
  , noMonitors
  , scriptedMonitor
  , seamCalls
  , seamLiveWindowCallbacks
  , seamQueueEvents
  , seamQueueMonitorEvents
  , seamSession
  , seamSetMonitorTopology
  )
import Hetoimasia.GLFW.Monitor (inventoryMonitors, inventoryRevision)
import Hetoimasia.GLFW.Session (SessionMisuse (..), defaultSessionConfig)
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Numeric.Natural (Natural)
import Hetoimasia.Runtime.Supervision
  ( Recognition (..)
  , Role (..)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  , startSupervised
  , supervisedWorker
  , workerStatus
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Test.GLFW.Window (boundedExample, caughtAs, current, entered, onThread, operationOf, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW window host" $ do
  describe "owner turns" $ do
    it "polls while active and waits its finite idle bound while idle, serving a command queued during an idle turn on the next"
      (boundedExample testPollThenWait)
    it "waits on every idle turn with no windows rather than spinning"
      (boundedExample testNoWindowsWait)
    it "refuses budgets and idle waits it cannot bound before acquiring anything"
      (boundedExample testConfigRejected)
    it "rolls a failed construction back before startup, releasing what it created"
      (boundedExample testConstructionRollback)

  describe "checkpoints under saturated queues" $ do
    it "rethrows a failure latched during event processing before any dispatch"
      (boundedExample (testPreemption AtEventProcessing))
    it "reaches the check after one command batch, charging rejected commands their attempt"
      (boundedExample (testPreemption AtCommand))
    it "reaches the check after one application event batch, before the update"
      (boundedExample (testPreemption AtApplicationEvent))

  describe "workers and the owner" $ do
    it "lets a background worker progress while the owner is inside its finite wait"
      (boundedExample testProgressDuringWait)
    it "settles a worker's observation request through the loop with the published revision"
      (boundedExample testObservationThroughLoop)
    it "rejects owner-thread waits on its own loop, and refuses the loop to another thread"
      (boundedExample testOwnerNeverWaits)

  describe "monitors" $
    it "refreshes the monitor inventory after native events only when the monitor callback reported a change"
      (boundedExample testMonitorReconciliation)

  describe "close requests" $
    it "surfaces a close request once to application policy, destroying nothing and keeping the loop and workers running"
      (boundedExample testCloseRequest)

  describe "quiescence and shutdown" $ do
    it "closes admission and settles queued commands in one finite, idempotent transaction that executes nothing"
      (boundedExample testQuiescence)
    it "closes a window's input feed with its close protocol, and every feed at quiescence, without awaiting a pending reset's acknowledgement"
      (boundedExample testInputFeedsClosed)
    it "settles queued callers before the boundary drain when startup fails after a worker started"
      (boundedExample (testSettledBeforeDrain StartupFails))
    it "settles queued callers before the boundary drain when the action returns"
      (boundedExample (testSettledBeforeDrain ActionReturns))
    it "settles queued callers before the boundary drain when the action fails"
      (boundedExample (testSettledBeforeDrain ActionFails))
    it "settles queued callers before the boundary drain when the action is cancelled"
      (boundedExample (testSettledBeforeDrain ActionCancelled))
    it "settles queued callers after a supervisor-detected failure, releasing the window only after the drain"
      (boundedExample testSupervisorDetectedFailure)
    it "drains an abandoned managed startup before quiescence, then settles queued callers and releases the window after the drain"
      (boundedExample testAbandonedStartup)

-- ---------------------------------------------------------------------------
-- Owner turns

testPollThenWait ∷ Expectation
testPollThenWait = do
  seam ← newSeam defaultScript
  (turns, ticket, window) ←
    hosted seam (settings [windowNamed "turns"]) (\host _ → pure host) $ \host control → do
      window ← onlyWindow host
      summaries ← newIORef []
      queued ← newIORef Nothing
      runOwnerLoop host control $
        LoopHooks
          { loopEvent = noApplicationEvents
          , loopUpdate = \turn → do
              modifyIORef' summaries (<> [summary turn])
              case turnNumber turn of
                2 → do
                  ticket ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
                  writeIORef queued (Just ticket)
                  pure Continue
                3 → do
                  ticket ← readIORef queued >>= maybe (unexpected "no command was queued") pure
                  Finish <$> ((,,) <$> readIORef summaries <*> pure ticket <*> pure window)
                _ → pure Continue
          }
  turns `shouldBe` [(1, False, 0, 0), (2, True, 0, 0), (3, False, 1, 0)]
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25, PollEvents]
  settled ← atomically (pollCompletion ticket)
  settled `shouldSatisfy` \case
    Just (Performed (ObservationPublished published _)) → published == windowIdentity window
    _ → False

testNoWindowsWait ∷ Expectation
testNoWindowsWait = do
  seam ← newSeam defaultScript
  turns ←
    hosted seam (settings []) {hostIdleWait = 0.5} (\host _ → pure host) $ \host control →
      runOwnerLoop host control $
        LoopHooks
          { loopEvent = noApplicationEvents
          , loopUpdate = \turn → pure (if turnNumber turn == 4 then Finish (turnNumber turn) else Continue)
          }
  turns `shouldBe` 4
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.5, WaitEvents 0.5, WaitEvents 0.5]

testConfigRejected ∷ Expectation
testConfigRejected = do
  let base = settings [windowNamed "never"]
  validateHostConfig base `shouldBe` Right ()
  validateHostConfig base {hostEventBudget = 0} `shouldBe` Left (EventBudgetRejected 0)
  map (idleRejected . validateHostConfig . (\wait → base {hostIdleWait = wait})) [0, -1, 1 / 0, 0 / 0, 61]
    `shouldBe` replicate 5 True
  seam ← newSeam defaultScript
  started ← newIORef False
  -- Caught on the bound thread itself: 'runInBoundThread' rethrows a failure
  -- without the context its origin is read from.
  (rejection, caught) ←
    asProcessMainThread seam . caughtAs $
      runWindowApplication lifetime "host-example" (hostOver seam base {hostCommandBudget = 0}) id
        (\_ _ → writeIORef started True)
        (\_ _ → pure ())
  rejection `shouldBe` CommandBudgetRejected 0
  operationOf caught `shouldBe` Just ("glfw.runtime", "construct window host")
  seamCalls seam `shouldReturn` []
  readIORef started `shouldReturn` False
  where
    idleRejected = \case
      Left (IdleWaitRejected _) → True
      _ → False

testConstructionRollback ∷ Expectation
testConstructionRollback = do
  seam ← newSeam defaultScript
  started ← newIORef False
  (rejection, _) ←
    caughtAs $
      hosted seam (settings [windowNamed "created", windowNamed "bad\NUL"]) (\_ _ → writeIORef started True) (\_ _ → pure ())
  rejection `shouldBe` WindowTitleRejected
  calls ← seamCalls seam
  [call | call@(DestroyWindow _) ← calls] `shouldBe` [DestroyWindow 1]
  [call | call ← calls, call `elem` [DestroyWindow 1, Terminate]] `shouldBe` [DestroyWindow 1, Terminate]
  seamLiveWindowCallbacks seam `shouldReturn` 0
  readIORef started `shouldReturn` False

-- ---------------------------------------------------------------------------
-- Checkpoints under saturated queues

-- | Where a required worker's failure is made to latch during the first turn.
data Trigger = AtEventProcessing | AtCommand | AtApplicationEvent
  deriving (Eq, Show)

-- | Six commands alternate between the host's window and a window it does not
-- serve, far more than one turn's budget of three, and the application event
-- opportunity is always ready. The failure is latched from inside the step the
-- trigger names, and the checks that follow must stop the turn there.
testPreemption ∷ Trigger → Expectation
testPreemption trigger = do
  fire ← newIORef (pure ())
  let once = join (atomicModifyIORef' fire (\action → (pure (), action)))
      script =
        defaultScript
          { scriptPollEvents = \_ → when (trigger == AtEventProcessing) once
          , scriptWindowSize = \_ → when (trigger == AtCommand) once >> pure (800, 600)
          }
  seam ← newSeam script
  elsewhere ← unservedWindow
  events ← newIORef (0 ∷ Int)
  updates ← newIORef (0 ∷ Int)
  ticketsSeen ← newIORef []
  (failure, _) ←
    caughtAs $
      hosted
        seam
        (settings [windowNamed "saturated"])
        ( \host control → do
            gate ← newEmptyMVar
            breaker ← startSupervised control (required Job) (breakingAfter gate) >>= expectStarted
            writeIORef fire (putMVar gate () >> void (atomically (Worker.awaitCompletion (supervisedWorker breaker))))
            window ← onlyWindow host
            tickets ← forM [1 .. 6 ∷ Int] $ \index →
              submitWindowCommand (hostCommandPort host) [] (observeWindowCommand (if odd index then windowIdentity window else elsewhere))
                >>= admitted
            writeIORef ticketsSeen tickets
            pure host
        )
        ( \host control →
            runOwnerLoop host control $
              LoopHooks
                { loopEvent = do
                    when (trigger == AtApplicationEvent) once
                    modifyIORef' events (+ 1)
                    pure True
                , loopUpdate = \_ → modifyIORef' updates (+ 1) >> pure Continue
                }
        )
  failure `shouldBe` Broken "worker failed"
  dispositions ← readIORef ticketsSeen >>= atomically . mapM pollCompletion
  let dispatched = if trigger == AtEventProcessing then [] else ["performed", "rejected", "performed"]
  map kind dispositions `shouldBe` dispatched <> replicate (6 - length dispatched) "not executed"
  readIORef events `shouldReturn` (if trigger == AtApplicationEvent then 2 else 0)
  readIORef updates `shouldReturn` 0

-- ---------------------------------------------------------------------------
-- Monitors

-- | A monitor disconnects during turn two's update. Turn three's native event
-- processing delivers the callback, and its reconciliation refreshes the
-- inventory before the update sees it; the idle turns before made no refresh.
testMonitorReconciliation ∷ Expectation
testMonitorReconciliation = do
  seam ←
    newSeam
      defaultScript
        {scriptMonitorTopology = MonitorTopology (Just [(1, scriptedMonitor "only" (0, 0) (1280, 1024))]) 1}
  seen ←
    hosted seam (settings []) (\host _ → pure host) $ \host control → do
      observed ← newIORef []
      runOwnerLoop host control $
        LoopHooks
          { loopEvent = noApplicationEvents
          , loopUpdate = \turn → do
              inventory ← preparedValue . observedValue <$> atomically (readSnapshot (hostMonitors host))
              modifyIORef' observed (<> [(turnNumber turn, inventoryRevision inventory, inventoryMonitors inventory == Observed [])])
              case turnNumber turn of
                2 → do
                  seamSetMonitorTopology seam noMonitors
                  seamQueueMonitorEvents seam [MonitorDetached 1]
                  pure Continue
                3 → Finish <$> readIORef observed
                _ → pure Continue
          }
  seen `shouldBe` [(1, 0, False), (2, 0, False), (3, 1, True)]
  calls ← seamCalls seam
  length [() | QueryMonitors ← calls] `shouldBe` 2

-- ---------------------------------------------------------------------------
-- Workers and the owner

testProgressDuringWait ∷ Expectation
testProgressDuringWait = do
  progress ← newTVarIO Nothing
  -- The seam's wait blocks until the worker has made progress, so the loop can
  -- only continue once the worker ran while the owner was inside the wait.
  seam ← newSeam defaultScript {scriptWaitEvents = \_ _ → atomically (readTVar progress >>= check . isJust)}
  (seen, finished) ←
    hosted
      seam
      (settings [windowNamed "waiting"])
      (\host control → startSupervised control (required Service) (progressing host progress) >>= expectStarted >> pure host)
      ( \host control →
          runOwnerLoop host control $
            LoopHooks
              { loopEvent = noApplicationEvents
              , loopUpdate = \turn →
                  readTVarIO progress >>= \case
                    Just recorded | turnWaited turn → pure (Finish (recorded, turnNumber turn))
                    _ → pure Continue
              }
      )
  seen `shouldBe` HostActivity 2 True
  finished `shouldBe` 2

testObservationThroughLoop ∷ Expectation
testObservationThroughLoop = do
  seam ← newSeam defaultScript
  result ← newTVarIO Nothing
  (settled, window, revision) ←
    hosted
      seam
      (settings [windowNamed "observed"])
      ( \host control → do
          window ← onlyWindow host
          _ ← startSupervised control (required Job) (requesting (hostCommandPort host) (windowIdentity window) result) >>= expectStarted
          pure host
      )
      ( \host control →
          runOwnerLoop host control $
            LoopHooks
              { loopEvent = noApplicationEvents
              , loopUpdate = \_ →
                  readTVarIO result >>= \case
                    Nothing → pure Continue
                    Just settled → do
                      window ← onlyWindow host
                      observation ← current window
                      pure (Finish (settled, windowIdentity window, observedRevision observation))
              }
      )
  settled `shouldBe` Just (Performed (ObservationPublished window revision))

testOwnerNeverWaits ∷ Expectation
testOwnerNeverWaits = do
  seam ← newSeam defaultScript
  (awaitMisuse, submitMisuse, offOwner) ←
    hosted seam (settings [windowNamed "owner"]) {hostCommandCapacity = 1} (\host _ → pure host) $ \host control →
      runOwnerLoop host control $
        LoopHooks
          { loopEvent = noApplicationEvents
          , loopUpdate = \_ → do
              window ← onlyWindow host
              let port = hostCommandPort host
              ticket ← submitWindowCommand port [] (observeOf window) >>= admitted
              (awaitMisuse, _) ← caughtAs (awaitCompletion ticket)
              (submitMisuse, _) ← caughtAs (awaitSubmitWindowCommand port [] (observeOf window))
              (offOwner, _) ←
                onThread forkIO . caughtAs $
                  runOwnerLoop host control (LoopHooks noApplicationEvents (\_ → pure (Finish ())))
              pure (Finish (awaitMisuse, submitMisuse, offOwner))
          }
  awaitMisuse `shouldBe` OwnerThreadWouldWait
  submitMisuse `shouldBe` OwnerThreadWouldWait
  offOwner `shouldBe` NotSessionOwner

-- ---------------------------------------------------------------------------
-- Close requests

testCloseRequest ∷ Expectation
testCloseRequest = do
  seam ← newSeam defaultScript
  surfaced ← newIORef []
  (window, (ended, phase, latched, live, destroyed, cleared, afterwards)) ←
    hosted
      seam
      (settings [windowNamed "closing"])
      ( \host control → do
          window ← onlyWindow host
          seamQueueEvents seam window [CloseRequested]
          service ← startSupervised control (required Service) untilStopped >>= expectStarted
          pure (host, service)
      )
      ( \(host, service) control → do
          window ← onlyWindow host
          outcome ←
            runOwnerLoop host control $
              LoopHooks
                { loopEvent = noApplicationEvents
                , loopUpdate = \turn → do
                    modifyIORef' surfaced (<> [turnCloseRequests turn])
                    if turnNumber turn < 3
                      then pure Continue
                      else Finish <$> policyAt seam surfaced host service window
                }
          pure (windowIdentity window, outcome)
      )
  requests ← readIORef surfaced
  map (map closeRequestWindow) requests `shouldBe` [[window], [], []]
  ended `shouldBe` False
  phase `shouldBe` WindowOpen
  latched `shouldBe` concat requests
  live `shouldBe` True
  destroyed `shouldBe` []
  cleared `shouldBe` [True]
  afterwards `shouldBe` Nothing

-- | The application's policy on the third turn, after the request surfaced on
-- the first: record that nothing was destroyed and the worker still runs, and
-- only then reject the request.
policyAt
  ∷ Seam
  → IORef [[CloseRequest]]
  → WindowHost
  → SupervisedWorker ()
  → Window
  → IO (Bool, WindowPhase, [CloseRequest], Bool, [NativeCall], [Bool], Maybe CloseRequest)
policyAt seam surfaced host service window = do
  requests ← concat <$> readIORef surfaced
  ended ← windowEnded window
  observation ← current window
  status ← atomically (workerStatus service)
  calls ← seamCalls seam
  cleared ← mapM (rejectHostCloseRequest host) requests
  afterwards ← observedCloseRequest <$> current window
  pure
    ( ended
    , observedPhase observation
    , maybe [] pure (observedCloseRequest observation)
    , isLive status
    , [call | call@(DestroyWindow _) ← calls]
    , cleared
    , afterwards
    )

-- ---------------------------------------------------------------------------
-- Quiescence and shutdown

testQuiescence ∷ Expectation
testQuiescence = do
  seam ← newSeam defaultScript
  (full, first, second, dispositions, late, sampled) ←
    hosted
      seam
      (settings [windowNamed "quiet"]) {hostCommandCapacity = 3}
      ( \host _ → do
          window ← onlyWindow host
          tickets ← replicateM 3 (submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted)
          pure (host, window, tickets)
      )
      ( \(host, window, tickets) _ → do
          full ← submitWindowCommand (hostCommandPort host) [] (observeOf window)
          before ← samples seam
          -- Each transaction commits, so neither retries.
          first ← atomically (quiesceWindowHost host >> hostCommandStatistics host)
          second ← atomically (quiesceWindowHost host >> hostCommandStatistics host)
          dispositions ← atomically (mapM pollCompletion tickets)
          late ← submitWindowCommand (hostCommandPort host) [] (observeOf window)
          after ← samples seam
          pure (full, first, second, dispositions, late, after - before)
      )
  full `shouldBe` SubmitFull
  first `shouldBe` CommandStatistics 3 0 0 0
  second `shouldBe` first
  dispositions `shouldBe` replicate 3 (Just NotExecuted)
  late `shouldBe` SubmitClosed
  sampled `shouldBe` 0

-- | Each window's client carries its own input feed. A window's close protocol
-- closes that feed, and quiescence closes the rest, even while a reset waits for
-- an acknowledgement no consumer will make.
testInputFeedsClosed ∷ Expectation
testInputFeedsClosed = do
  validateHostConfig (settings []) {hostInputCapacity = 0} `shouldBe` Left (InputCapacityRejected 0)
  seam ← newSeam defaultScript
  (closedByClose, pending, closedByQuiescence, frozen) ←
    hosted seam (settings [windowNamed "kept", windowNamed "closed"]) (\host _ → pure host) $ \host _ → do
      (kept, closing) ←
        atomically (mapM (hostWindowClient host) =<< hostWindowIdentities host) >>= \case
          [Just kept, Just closing] → pure (kept, closing)
          clients → unexpected ("expected two window clients, found " <> show clients)
      Input.inputReaderWindow (clientInputReader kept) `shouldBe` clientWindow kept
      atomically (Input.enableInput (clientInputControl kept)) `shouldReturn` Input.AdmissionOpened
      token ←
        atomically (Input.suspendInput (clientInputControl kept)) >>= \case
          Input.AdmissionReset token → pure token
          other → unexpected ("suspension began no reset: " <> show other)
      closeHostWindow host (clientWindow closing) `shouldReturn` CloseStarted
      closedByClose ← atomically (Input.readInput (clientInputReader closing))
      pending ← atomically (Input.readInput (clientInputReader kept))
      pending `shouldBe` Input.InputResetRequired token
      atomically (quiesceWindowHost host)
      closedByQuiescence ← atomically (Input.awaitInput (clientInputReader kept))
      frozen ← atomically (Input.inputStatistics (clientInputReader kept))
      pure (closedByClose, pending, closedByQuiescence, frozen)
  closedByClose `shouldBe` Input.InputClosed
  pending `shouldSatisfy` (/= Input.InputClosed)
  closedByQuiescence `shouldBe` Input.InputClosed
  (Input.statisticsPhase frozen, Input.statisticsResets frozen) `shouldBe` (Input.InputFeedClosed, 1)

-- | How a run leaves the supervised region while a worker waits on a queued
-- command.
data Exit = StartupFails | ActionReturns | ActionFails | ActionCancelled
  deriving (Eq, Show)

-- | A job files a command no turn will serve and waits for that command alone,
-- ignoring its stop token. Its release runs as the job is drained, whether it
-- returned or was cancelled, and records whether the command had settled and
-- whether its window was still live: the settlement must precede the drain, and
-- the window's destruction must follow it.
testSettledBeforeDrain ∷ Exit → Expectation
testSettledBeforeDrain exit = do
  seam ← newSeam defaultScript
  journal ← newTVarIO []
  waiting ← newTVarIO False
  filed ← newTVarIO Nothing
  held ← newIORef Nothing
  inside ← newEmptyMVar
  let run =
        runWindowApplication lifetime "host-example" (hostOver seam (settings [windowNamed "drained"])) id
          ( \host control → do
              window ← onlyWindow host
              writeIORef held (Just window)
              _ ← startSupervised control (required Job) (parkedRequester journal (pure ()) waiting filed window (hostCommandPort host)) >>= expectStarted
              awaitSupervised control (readTVar waiting >>= check)
              when (exit == StartupFails) (throwIO (Broken "startup failed"))
          )
          ( \() control → case exit of
              ActionFails → throwIO (Broken "action failed")
              ActionCancelled → putMVar inside () >> awaitSupervised control retry
              _ → pure ()
          )
  (runner, finished) ← onMainThread seam run
  when (exit == ActionCancelled) $ do
    takeMVar inside
    awaitBlockedOnSTM runner
    killThread runner
  outcome ← takeMVar finished
  case (exit, outcome) of
    (ActionReturns, Right ()) → pure ()
    (ActionCancelled, Left caught) | fromException caught == Just ThreadKilled → pure ()
    (StartupFails, Left caught) | fromException caught == Just (Broken "startup failed") → pure ()
    (ActionFails, Left caught) | fromException caught == Just (Broken "action failed") → pure ()
    _ → unexpected ("the run ended with " <> either displayException (const "its result") outcome)
  readTVarIO journal `shouldReturn` ["released with NotExecuted while its window was live"]
  heldWindow held >>= windowEnded >>= (`shouldBe` True)

testSupervisorDetectedFailure ∷ Expectation
testSupervisorDetectedFailure = do
  seam ← newSeam defaultScript
  journal ← newTVarIO []
  waiting ← newTVarIO False
  filed ← newTVarIO Nothing
  release ← newEmptyMVar
  gate ← newEmptyMVar
  held ← newIORef Nothing
  (failure, _) ←
    caughtAs $
      hosted
        seam
        (settings [windowNamed "detected"])
        ( \host control → do
            window ← onlyWindow host
            writeIORef held (Just window)
            _ ← startSupervised control (required Job) (parkedRequester journal (takeMVar release) waiting filed window (hostCommandPort host)) >>= expectStarted
            breaker ← startSupervised control (required Job) (breakingAfter gate) >>= expectStarted
            pure (host, breaker)
        )
        ( \(host, breaker) control → do
            first ← newIORef True
            runOwnerLoop host control $
              LoopHooks
                { loopEvent = do
                    firstEvent ← atomicModifyIORef' first (\isFirst → (False, isFirst))
                    when firstEvent $ do
                      -- The requester's command is queued after this turn's
                      -- command work, and the breaker fails before the check
                      -- that follows the event work.
                      putMVar release ()
                      awaitSupervised control (readTVar waiting >>= check)
                      putMVar gate ()
                      void (atomically (Worker.awaitCompletion (supervisedWorker breaker)))
                    pure firstEvent
                , loopUpdate = \_ → pure Continue
                }
        )
  failure `shouldBe` Broken "worker failed"
  -- The fatal latch asks the requester to stop before quiescence runs; it
  -- ignores that, and is drained only after quiescence settled its command.
  readTVarIO journal `shouldReturn` ["released with NotExecuted while its window was live"]
  heldWindow held >>= windowEnded >>= (`shouldBe` True)

testAbandonedStartup ∷ Expectation
testAbandonedStartup = do
  seam ← newSeam defaultScript
  journal ← newTVarIO []
  waiting ← newTVarIO False
  filed ← newTVarIO Nothing
  inside ← newEmptyMVar
  never ← newEmptyMVar
  held ← newIORef Nothing
  let stalled =
        workerDefinition
          "stalled"
          ( \_ → do
              allocResource (pure ()) $ \() → do
                settled ← settlementOf filed
                atomically (note journal ("released the stalled startup with the requester's command " <> maybe "unsettled" (Text.pack . show) settled))
              liftIO (putMVar inside () >> takeMVar never)
          )
          (\_ () → pure ())
      run =
        runWindowApplication lifetime "host-example" (hostOver seam (settings [windowNamed "abandoned"])) id
          ( \host control → do
              window ← onlyWindow host
              writeIORef held (Just window)
              _ ← startSupervised control (required Job) (parkedRequester journal (pure ()) waiting filed window (hostCommandPort host)) >>= expectStarted
              awaitSupervised control (readTVar waiting >>= check)
              void (startSupervised control (required Service) stalled)
          )
          (\() _ → pure ())
  (runner, finished) ← onMainThread seam run
  takeMVar inside
  awaitBlockedOnSTM runner
  killThread runner
  takeMVar finished >>= \case
    Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
    Right () → unexpected "the cancelled application returned"
  readTVarIO journal
    `shouldReturn` [ "released the stalled startup with the requester's command unsettled"
                   , "released with NotExecuted while its window was live"
                   ]
  heldWindow held >>= windowEnded >>= (`shouldBe` True)

-- ---------------------------------------------------------------------------
-- Applications and workers

-- | A logging lifetime whose records go nowhere.
lifetime ∷ (LoggingLifetime → IO r) → IO r
lifetime = withLoggingLifetime (mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ())))

hostOver ∷ Seam → HostConfig → Scoped WindowHost
hostOver seam = allocWindowHostIn (seamSession seam defaultSessionConfig)

-- | Run an application over a host in the seam's session, on a bound thread
-- designated as the process main thread.
hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hosted seam config startup action =
  asProcessMainThread seam (runWindowApplication lifetime "host-example" (hostOver seam config) id startup action)

-- | Run an action on a new bound thread designated as the process main thread,
-- so an example can cancel it.
onMainThread ∷ ∀ a. Seam → IO a → IO (ThreadId, MVar (Either SomeException a))
onMainThread seam action = do
  finished ← newEmptyMVar
  runner ← forkOS (designateProcessMainThread seam >> (try action ∷ IO (Either SomeException a)) >>= putMVar finished)
  pure (runner, finished)

settings ∷ [WindowConfig] → HostConfig
settings windows =
  (defaultHostConfig windows)
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.25
    }

windowNamed ∷ Text → WindowConfig
windowNamed name = hiddenTestWindowConfig name 64 48

-- | The host's only window, on the owner thread. It is taken out of its borrow
-- so an example can inspect its terminal state after the run; the examples only
-- read it, and never keep it across its release on the owner thread.
onlyWindow ∷ WindowHost → IO Window
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] → withHostWindow host identity pure >>= \case
      WindowAvailable window → pure window
      WindowEnded _ → unexpected "the host's only window has ended"
    windows → unexpected ("expected one window, found " <> show (length windows))

heldWindow ∷ IORef (Maybe Window) → IO Window
heldWindow held = readIORef held >>= maybe (unexpected "no window was built") pure

-- | The identity of a window no host in the example serves.
unservedWindow ∷ IO WindowId
unservedWindow = do
  seam ← newSeam defaultScript
  asProcessMainThread seam (entered seam (\session → withWindow session (windowNamed "elsewhere") (pure . windowIdentity)))

observeOf ∷ Window → WindowCommand
observeOf = observeWindowCommand . windowIdentity

admitted ∷ SubmitResult → IO CompletionTicket
admitted (SubmitAccepted ticket) = pure ticket
admitted other = unexpected ("the submission was not admitted: " <> show other)

summary ∷ Turn → (Natural, Bool, Int, Int)
summary turn = (turnNumber turn, turnWaited turn, turnCommands turn, turnEvents turn)

-- | The native event processing calls, in order.
pumps ∷ Seam → IO [NativeCall]
pumps seam = filter pumped <$> seamCalls seam
  where
    pumped = \case
      PollEvents → True
      WaitEvents _ → True
      _ → False

-- | How many times a window has been sampled so far.
samples ∷ Seam → IO Int
samples seam = length . filter (== QueryWindowSize) <$> seamCalls seam

kind ∷ Maybe Disposition → String
kind = \case
  Nothing → "pending"
  Just (Performed _) → "performed"
  Just (Rejected _) → "rejected"
  Just NotExecuted → "not executed"
  Just (Interrupted _) → "interrupted"
  Just (Unsupported _) → "unsupported"
  Just (Attempted _) → "attempted"
  Just (Transitioned _) → "transitioned"

isLive ∷ WorkerStatus → Bool
isLive WorkerLive = True
isLive _ = False

newtype Broken = Broken Text
  deriving (Eq, Show)

instance Exception Broken

testComponent ∷ Component
testComponent = unsafeComponent "test.host"

required ∷ Role → WorkerPolicy
required role = WorkerPolicy role Supervision.Required testComponent (\_ → pure Unrecognized)

expectStarted ∷ SupervisedStart r → IO (SupervisedWorker r)
expectStarted = \case
  WorkerStarted worker → pure worker
  WorkerStartUnavailable _ _ → unexpected "the worker was unavailable"
  WorkerStartRejected → unexpected "the worker's start was rejected"

breakingAfter ∷ MVar () → WorkerDefinition ()
breakingAfter gate = workerDefinition "breaker" (\_ → pure ()) (\_ () → takeMVar gate >> throwIO (Broken "worker failed"))

untilStopped ∷ WorkerDefinition ()
untilStopped = workerDefinition "idle" (\_ → pure ()) (\token () → atomically (awaitStopRequest token))

-- | A service that records the host's activity once it sees the owner inside a
-- finite wait, in the transaction that saw it.
progressing ∷ WindowHost → TVar (Maybe HostActivity) → WorkerDefinition ()
progressing host progress =
  workerDefinition "progressing" (\_ → pure ()) $ \token () → do
    atomically $ do
      activity ← hostActivity host
      check (activityWaiting activity)
      writeTVar progress (Just activity)
    atomically (awaitStopRequest token)

-- | A job that requests an observation from a running loop, composing its wait
-- with its stop request.
requesting ∷ WindowCommandPort → WindowId → TVar (Maybe (Maybe Disposition)) → WorkerDefinition ()
requesting port target result =
  workerDefinition "requester" (\_ → pure ()) $ \token () → do
    settled ←
      awaitSubmitWindowCommand port [("client", "requester")] (observeWindowCommand target) >>= \case
        WaitAccepted ticket → awaitOrStop token ticket
        WaitClosed → pure Nothing
    atomically (writeTVar result (Just settled))

awaitOrStop ∷ StopToken → CompletionTicket → IO (Maybe Disposition)
awaitOrStop token ticket =
  atomically $
    (Just <$> (pollCompletion ticket >>= maybe retry pure))
      `orElse` (Nothing <$ awaitStopRequest token)

-- | A job that, after @before@, files one command and waits for that command
-- alone, ignoring its stop token. Its release notes whether the command had
-- settled and whether its window was still live.
parkedRequester
  ∷ TVar [Text]
  → IO ()
  → TVar Bool
  → TVar (Maybe CompletionTicket)
  → Window
  → WindowCommandPort
  → WorkerDefinition ()
parkedRequester journal before waiting filed window port =
  workerDefinition
    "parked requester"
    ( \_ →
        allocResource (pure ()) $ \() → do
          settled ← settlementOf filed
          ended ← windowEnded window
          atomically . note journal $
            "released with "
              <> maybe "its command unsettled" (Text.pack . show) settled
              <> if ended then " after its window was destroyed" else " while its window was live"
    )
    ( \_ () → do
        before
        ticket ← submitWindowCommand port [] (observeOf window) >>= admitted
        atomically (writeTVar filed (Just ticket) >> writeTVar waiting True)
        void (atomically (pollCompletion ticket >>= maybe retry pure))
    )

-- | How a filed command has settled so far, if one was filed.
settlementOf ∷ TVar (Maybe CompletionTicket) → IO (Maybe Disposition)
settlementOf filed = readTVarIO filed >>= maybe (pure Nothing) (atomically . pollCompletion)

note ∷ TVar [Text] → Text → STM ()
note journal entry = modifyTVar' journal (<> [entry])

-- | Wait until a thread is parked in a transaction.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM target =
  threadStatus target >>= \case
    ThreadBlocked BlockedOnSTM → pure ()
    ThreadFinished → unexpected "the thread finished instead of waiting"
    ThreadDied → unexpected "the thread died instead of waiting"
    _ → yield >> awaitBlockedOnSTM target
