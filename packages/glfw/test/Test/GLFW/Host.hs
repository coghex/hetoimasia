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

import Control.Concurrent (ThreadId, forkIO, forkOS, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (forM, join, replicateM, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.ByteString (ByteString)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , LogLevel (Warning)
  , Logger
  , callbackSink
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  , unsafeComponent
  )
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds, scriptedInstant)
import Hetoimasia.Foundation.Worker (StopToken, WorkerDefinition, awaitStopRequest, workerDefinition)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Demand
import Hetoimasia.GLFW.Internal.Demand (DemandHooks (..), noDemandHooks, publishDemandWith)
import qualified Hetoimasia.GLFW.Input as Input
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Internal.Seam
  ( MonitorTopology (..)
  , NativeCall (..)
  , Seam
  , SeamMonitorEvent (MonitorDetached)
  , SeamScript (..)
  , WindowEvent (CharEventAt, CloseRequested, FocusChanged)
  , asProcessMainThread
  , defaultScript
  , designateProcessMainThread
  , AdmissionHooks (..)
  , newSeam
  , noAdmissionHooks
  , noMonitors
  , reportError
  , submitWith
  , scriptedMonitor
  , seamCalls
  , seamLiveWindowCallbacks
  , seamQueueControlEvents
  , seamQueueEvents
  , seamQueueMonitorEvents
  , seamSession
  , seamSetMonitorTopology
  )
import Hetoimasia.GLFW.Monitor (inventoryMonitors, inventoryRevision)
import Hetoimasia.GLFW.Session
  ( DegradationAttempt (..)
  , DegradationReport (..)
  , SessionMisuse (..)
  , WakeOutcome (..)
  , WakePath (..)
  , defaultSessionConfig
  , sessionWake
  , wakeSession
  )
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
import Test.GLFW.Support (boundedExample, caughtAs, current, entered, onThread, operationOf, unexpected)
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
    it "claims the overflow warning through the injected loop logger and resumes after acknowledgement at the owner-loop recovery boundary"
      (boundedExample testOwnerLoopRecoversFeed)
    it "recovers a feed overflowed by command-triggered callbacks at the post-command boundary"
      (boundedExample testOwnerLoopRecoversFeedAfterCommand)
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

  describe "wake and demand" $ do
    it "ends an idle turn's finite wait when a worker's admitted command wakes the owner, and serves it in that turn's own command work"
      (boundedExample testCommandWakesIdleWait)
    it "ends an idle turn's finite wait when a worker publishes demand, which that turn's update captures with its revision"
      (boundedExample testDemandWakesIdleWait)
    it "closes a window's demand slot with its close protocol and every slot at quiescence, rejecting retained publishers afterwards"
      (boundedExample testDemandSlotsClosed)
    it "registers a window whose creation was claimed before quiescence with its port and demand slot already closed"
      (boundedExample testCreationRacingQuiescence)
    it "reports a degraded wake path once through the loop logger, and keeps waiting its finite idle bound"
      (boundedExample testDegradationReportedByLoop)
    it "lends no port or demand publisher, and wakes nothing, when host construction rolls back"
      (boundedExample testRollbackLendsNothing)
    it "shares one degradation and one report between sequential hosts borrowing the same session"
      (boundedExample testDegradationSharedByBorrowedHosts)
    it "reports a degradation the final update caused before the loop it finishes returns"
      (boundedExample testDegradationOnTheFinalTurn)
    it "waits for a notification still inside its post as the loop ends, and reports the degradation it leaves"
      (boundedExample testDegradationInFlightAtExit)
    it "reports a degradation as a failing loop ends, keeping the loop's own failure primary"
      (boundedExample testDegradationReportedOnFailingExit)
    it "claims a degradation begun after the loop, at the application's own boundary after quiescence"
      (boundedExample testDegradationAfterTheLoop)
    it "reports a degradation begun after the loop through the ordinary runner, with no reporting call of its own"
      (boundedExample testRunnerReportsWithoutBeingAsked)
    it "waits at the runner's boundary for a command paused between its commit and its wake"
      (boundedExample (testObligationHeldAfterCommit AdmittedCommand))
    it "waits at the runner's boundary for a demand publication paused between its commit and its wake"
      (boundedExample (testObligationHeldAfterCommit PublishedDemand))
    it "reports a degradation when startup fails, when the action fails, and when the run is cancelled"
      (boundedExample testReportsOnEveryExit)
    it "records a reporting attempt cancelled at its sink, outside any uninterruptible release"
      (boundedExample testReportingIsInterruptible)
    it "spends the reporting attempt for a notification still in its post when the run is cancelled at that wait"
      (boundedExample testCancelledDuringTheFinalWait)
    it "spends the reporting attempt for a cancellation requested as the action returns, before the attempt is protected"
      (boundedExample testCancelledAsTheActionReturns)
    it "spends the reporting attempt when a custom shutdown's own boundary is cancelled at its wait"
      (boundedExample testCancelledDuringACustomShutdown)
    it "ends a run whose worker keeps publishing until supervision stops it, on a finish and on a cancellation"
      (boundedExample testPublisherUntilStopped)

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
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
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
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
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
                { loopLogger = quietLogger
                , loopEvent = do
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
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
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
              { loopLogger = quietLogger
              , loopEvent = noApplicationEvents
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
              { loopLogger = quietLogger
              , loopEvent = noApplicationEvents
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
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
          , loopUpdate = \_ → do
              window ← onlyWindow host
              let port = hostCommandPort host
              ticket ← submitWindowCommand port [] (observeOf window) >>= admitted
              (awaitMisuse, _) ← caughtAs (awaitCompletion ticket)
              (submitMisuse, _) ← caughtAs (awaitSubmitWindowCommand port [] (observeOf window))
              (offOwner, _) ←
                onThread forkIO . caughtAs $
                  runOwnerLoop host control (LoopHooks quietLogger noApplicationEvents (\_ → pure (Finish ())))
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
                { loopLogger = quietLogger
                , loopEvent = noApplicationEvents
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

-- | Overflow from queued callbacks is warned through loopLogger and resumed by
-- recoverFeeds after acknowledgement, without the example calling
-- attemptOverflowWarning or resumeInput itself.
testOwnerLoopRecoversFeed ∷ Expectation
testOwnerLoopRecoversFeed = do
  seam ← newSeam defaultScript
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (entry :)))
  (messages, phase, epoch) ←
    hosted seam ((settings [windowNamed "input"]) {hostInputCapacity = 2}) (\host _ → pure host) $ \host control →
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = capturing
          , loopEvent = noApplicationEvents
          , loopUpdate = \turn →
              case turnNumber turn of
                1 → do
                  window ← onlyWindow host
                  client ← windowClient host window
                  atomically (Input.enableInput (clientInputControl client)) `shouldReturn` Input.AdmissionOpened
                  seamQueueEvents
                    seam
                    window
                    (FocusChanged True : replicate 3 (CharEventAt (fromEnum 'x')))
                  pure Continue
                2 → do
                  window ← onlyWindow host
                  client ← windowClient host window
                  atomically (Input.readInput (clientInputReader client)) >>= \case
                    Input.InputResetRequired token → do
                      atomically (Input.acknowledgeReset (clientInputReader client) token) `shouldReturn` Right Input.Acknowledged
                      pure Continue
                    other → unexpected ("expected a reset after overflow: " <> show other)
                3 → do
                  window ← onlyWindow host
                  client ← windowClient host window
                  statistics ← atomically (Input.inputStatistics (clientInputReader client))
                  logged ← reverse <$> readIORef warnings
                  map entryLevel logged `shouldBe` [Warning]
                  map (componentText . entryComponent) logged `shouldBe` ["glfw.input"]
                  pure
                    ( Finish
                        ( map entryMessage logged
                        , Input.statisticsPhase statistics
                        , Input.epochNumber (Input.statisticsEpoch statistics)
                        )
                    )
                _ → unexpected "the recovery did not finish within three turns"
          }
  messages `shouldBe` ["Input overflowed; the feed was reset"]
  phase `shouldBe` Input.InputRunning
  epoch `shouldBe` 2

testOwnerLoopRecoversFeedAfterCommand ∷ Expectation
testOwnerLoopRecoversFeedAfterCommand = do
  seam ← newSeam defaultScript
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (entry :)))
  (messages, phase, epoch) ←
    hosted seam ((settings [windowNamed "input"]) {hostInputCapacity = 2}) (\host _ → pure host) $ \host control →
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = capturing
          , loopEvent = noApplicationEvents
          , loopUpdate = \turn →
              case turnNumber turn of
                1 → do
                  window ← onlyWindow host
                  client ← windowClient host window
                  atomically (Input.enableInput (clientInputControl client)) `shouldReturn` Input.AdmissionOpened
                  seamQueueControlEvents
                    seam
                    window
                    (FocusChanged True : replicate 3 (CharEventAt (fromEnum 'x')))
                  _ ← submitWindowCommand (clientCommandPort client) [] (setWindowTitleCommand (windowIdentity window) "renamed") >>= admitted
                  pure Continue
                2 → do
                  window ← onlyWindow host
                  client ← windowClient host window
                  atomically (Input.readInput (clientInputReader client)) >>= \case
                    Input.InputResetRequired token → do
                      atomically (Input.acknowledgeReset (clientInputReader client) token) `shouldReturn` Right Input.Acknowledged
                      logged ← reverse <$> readIORef warnings
                      map entryMessage logged `shouldBe` ["Input overflowed; the feed was reset"]
                      pure Continue
                    other → unexpected ("expected a reset after a command setter: " <> show other)
                3 → do
                  window ← onlyWindow host
                  client ← windowClient host window
                  statistics ← atomically (Input.inputStatistics (clientInputReader client))
                  logged ← reverse <$> readIORef warnings
                  pure
                    ( Finish
                        ( map entryMessage logged
                        , Input.statisticsPhase statistics
                        , Input.epochNumber (Input.statisticsEpoch statistics)
                        )
                    )
                _ → unexpected "the command recovery did not finish within three turns"
          }
  messages `shouldBe` ["Input overflowed; the feed was reset"]
  phase `shouldBe` Input.InputRunning
  epoch `shouldBe` 2

-- ---------------------------------------------------------------------------
-- Wake and demand

-- | The scripted platform's pending empty-event posts and whether the owner is
-- inside a finite wait. A wait ends only when something posted, so a loop that
-- continues proves it was woken rather than timed out.
data WakePlatform = WakePlatform
  { platformPending ∷ TVar Int
  , platformWaiting ∷ TVar Bool
  }

newWakePlatform ∷ IO WakePlatform
newWakePlatform = WakePlatform <$> newTVarIO 0 <*> newTVarIO False

wakePlatformScript ∷ WakePlatform → SeamScript → SeamScript
wakePlatformScript platform script =
  script
    { scriptPostEmptyEvent = \reporter → do
        atomically (modifyTVar' (platformPending platform) (+ 1))
        scriptPostEmptyEvent script reporter
    , scriptPollEvents = \reporter → do
        atomically (writeTVar (platformPending platform) 0)
        scriptPollEvents script reporter
    , scriptWaitEvents = \seconds reporter → do
        atomically (writeTVar (platformWaiting platform) True)
        atomically $ do
          readTVar (platformPending platform) >>= check . (> 0)
          writeTVar (platformPending platform) 0
          writeTVar (platformWaiting platform) False
        scriptWaitEvents script seconds reporter
    }

-- | Run an action once the owner has entered its finite wait.
duringTheWait ∷ WakePlatform → IO () → IO ()
duringTheWait platform action =
  void . forkIO $ do
    atomically (readTVar (platformWaiting platform) >>= check)
    action

-- | The disposition a ticket settled to, read twice so a settled cell is shown
-- to be written once and never written again.
settledExactlyOnce ∷ CompletionTicket → IO Disposition
settledExactlyOnce ticket = do
  first ← atomically (pollCompletion ticket)
  again ← atomically (pollCompletion ticket)
  case (first, again) of
    (Just disposition, Just repeated)
      | disposition == repeated → pure disposition
    _ → unexpected ("the ticket did not settle exactly once: " <> show (first, again))

-- | A scripted platform whose every empty-event post reports the expected
-- platform failure, so the first notification degrades the session's wake path.
failingPostScript ∷ ByteString → SeamScript
failingPostScript description =
  defaultScript {scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 description}

-- | How many empty-event posts the seam recorded.
posts ∷ Seam → IO Int
posts seam = length . filter (== PostEmptyEvent) <$> seamCalls seam

testCommandWakesIdleWait ∷ Expectation
testCommandWakesIdleWait = do
  platform ← newWakePlatform
  seam ← newSeam (wakePlatformScript platform defaultScript)
  (settled, turns) ←
    hosted seam (settings [windowNamed "woken"]) (\host _ → pure host) $ \host control → do
      window ← onlyWindow host
      summaries ← newIORef []
      ticket ← newEmptyMVar
      duringTheWait
        platform
        (submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted >>= putMVar ticket)
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
          , loopUpdate = \turn → do
              modifyIORef' summaries (<> [summary turn])
              if turnNumber turn == 3
                then do
                  settled ← takeMVar ticket >>= settledExactlyOnce
                  Finish . (,) settled <$> readIORef summaries
                else pure Continue
          }
  -- The second turn's wait ended only because the admission woke the owner, so
  -- that turn's own command work served the command instead of the wait running
  -- to its bound.
  turns `shouldBe` [(1, False, 0, 0), (2, True, 1, 0), (3, False, 0, 0)]
  -- The woken turn's own command work settled the command exactly once.
  settled `shouldSatisfy` \case
    Performed (ObservationPublished _ _) → True
    _ → False
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25, PollEvents]
  posts seam `shouldReturn` 1

testDemandWakesIdleWait ∷ Expectation
testDemandWakesIdleWait = do
  platform ← newWakePlatform
  seam ← newSeam (wakePlatformScript platform defaultScript)
  (turns, captured, again) ←
    hosted seam (settings []) (\host _ → pure host) $ \host control → do
      summaries ← newIORef []
      taken ← newIORef Nothing
      duringTheWait platform (void (publishDemand (hostDemandPublisher host) immediateDemand))
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
          , loopUpdate = \turn → do
              modifyIORef' summaries (<> [summary turn])
              if turnWaited turn
                then do
                  writeIORef taken =<< captureHostDemand host
                  again ← captureHostDemand host
                  finished ← readIORef summaries
                  captured ← readIORef taken
                  pure (Finish (finished, captured, again))
                else pure Continue
          }
  -- The wait ended on the publication's wake, and the update of that same turn
  -- captured what had been published.
  turns `shouldBe` [(1, False, 0, 0), (2, True, 0, 0)]
  fmap capturedRevision captured `shouldBe` Just 1
  fmap (demandIsImmediate . capturedRequest) captured `shouldBe` Just True
  again `shouldBe` Nothing
  posts seam `shouldReturn` 1

testDemandSlotsClosed ∷ Expectation
testDemandSlotsClosed = do
  seam ← newSeam defaultScript
  (published, afterClose, hostPublished, afterQuiescence, retained) ←
    hosted seam (settings [windowNamed "slotted"]) (\host _ → pure host) $ \host _ → do
      window ← onlyWindow host
      client ← windowClient host window
      let publisher = clientDemandPublisher client
      published ← publishDemand publisher immediateDemand
      closeHostWindow host (windowIdentity window) `shouldReturn` CloseStarted
      afterClose ← publishDemand publisher immediateDemand
      hostPublished ← publishDemand (hostDemandPublisher host) (deadlineDemand (scriptedInstant (durationOf 1000)))
      atomically (quiesceWindowHost host)
      afterQuiescence ← publishDemand (hostDemandPublisher host) immediateDemand
      pure (published, afterClose, hostPublished, afterQuiescence, (publisher, hostDemandPublisher host))
  published `shouldBe` DemandPublished 1
  afterClose `shouldBe` DemandSlotClosed
  hostPublished `shouldBe` DemandPublished 1
  afterQuiescence `shouldBe` DemandSlotClosed
  -- Retained after the whole application ended: still typed rejections, and no
  -- native call.
  before ← posts seam
  publishDemand (fst retained) immediateDemand `shouldReturn` DemandSlotClosed
  publishDemand (snd retained) immediateDemand `shouldReturn` DemandSlotClosed
  posts seam `shouldReturn` before

testCreationRacingQuiescence ∷ Expectation
testCreationRacingQuiescence = do
  claimed ← newEmptyMVar
  release ← newEmptyMVar
  firstCreation ← newIORef True
  seam ←
    newSeam
      defaultScript
        { scriptCreateWindow = \_ → do
            first ← atomicModifyIORef' firstCreation (\flag → (False, flag))
            when first (putMVar claimed () >> takeMVar release)
            pure True
        }
  (disposition, submission, publication, identities) ←
    hosted seam (settings []) (\host _ → pure host) $ \host control → do
      ticket ←
        submitWindowCommand (hostCommandPort host) [] (createWindowCommand (windowNamed "late")) >>= admitted
      -- Quiescence commits while the creation is claimed and inside its native
      -- call, so the window is registered after admission has already ended.
      void . forkIO $ do
        takeMVar claimed
        atomically (quiesceWindowHost host)
        putMVar release ()
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = quietLogger
          , loopEvent = noApplicationEvents
          , loopUpdate = \_ → do
              disposition ← atomically (pollCompletion ticket)
              client ← atomically (pollWindowClient ticket)
              case (disposition, client) of
                (Just settled, Just capabilities) → do
                  submission ← submitWindowCommand (clientCommandPort capabilities) [] (observeWindowCommand (clientWindow capabilities))
                  publication ← publishDemand (clientDemandPublisher capabilities) immediateDemand
                  identities ← atomically (hostWindowIdentities host)
                  pure (Finish (settled, submission, publication, identities))
                _ → pure Continue
          }
  disposition `shouldSatisfy` \case
    Performed (WindowCreated _) → True
    _ → False
  -- The window exists and is disposed at shutdown, but nothing about it admits.
  length identities `shouldBe` 1
  submission `shouldBe` SubmitClosed
  publication `shouldBe` DemandSlotClosed

testDegradationReportedByLoop ∷ Expectation
testDegradationReportedByLoop = do
  seam ←
    newSeam
      defaultScript {scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 "scripted wake failure"}
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (<> [entry])))
  queued ← hosted seam (settings [windowNamed "degraded"]) (\host _ → pure host) $ \host control → do
    window ← onlyWindow host
    -- The first admission's wake fails as an expected platform failure. The
    -- answer, and the ticket, are the ordinary ones.
    degraded ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
    later ← newEmptyMVar
    runOwnerLoop host control $
      LoopHooks
        { loopLogger = capturing
        , loopEvent = noApplicationEvents
        , loopUpdate = \turn → do
            -- A later admission, after the degraded path has skipped its wake.
            when (turnNumber turn == 4) $ do
              queued ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
              putMVar later queued
            if turnNumber turn == 4
              then do
                -- The first admission's ticket was unaffected by its failed
                -- wake; the second is settled by the shutdown that follows.
                settled ← settledExactlyOnce degraded
                settled `shouldSatisfy` \case
                  Performed (ObservationPublished _ _) → True
                  _ → False
                Finish <$> takeMVar later
              else pure Continue
        }
  -- Quiescence settled the command still queued at shutdown, exactly once.
  settledExactlyOnce queued `shouldReturn` NotExecuted
  written ← readIORef warnings
  map (componentText . entryComponent) written `shouldBe` ["glfw.wake"]
  map entryLevel written `shouldBe` [Warning]
  -- One post: the degraded path skips every later admission's wake, and the
  -- loop keeps its finite idle bound.
  posts seam `shouldReturn` 1
  pumps seam `shouldReturn` [PollEvents, PollEvents, WaitEvents 0.25, WaitEvents 0.25]

durationOf ∷ Integer → Duration
durationOf nanoseconds = case durationFromNanoseconds AllowZero nanoseconds of
  Right duration → duration
  Left rejected → error ("the scripted duration was rejected: " <> show rejected)

-- | A notification still inside its post when the loop ends. The loop's own
-- boundary waits for nothing and claims nothing, because there is nothing
-- recorded yet; the runner's boundary, after quiescence has closed every source,
-- waits for that obligation and reports what it left.
testDegradationInFlightAtExit ∷ Expectation
testDegradationInFlightAtExit = do
  held ← newEmptyMVar
  release ← newEmptyMVar
  firstPost ← newIORef True
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            reportError reporter 0x00010008 "scripted wake failure"
            first ← atomicModifyIORef' firstPost (\flag → (False, flag))
            -- The first notification reports its failure and then stays inside
            -- its post until the example lets it leave.
            when first (putMVar held () >> takeMVar release)
        }
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = recordingLogger warnings
  (duringUpdate, admitted') ←
    hostedLogging capturing seam (settings [windowNamed "in flight"]) (\host _ → pure host) $ \host control → do
      window ← onlyWindow host
      owner ← myThreadId
      submitted ← newEmptyMVar
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = capturing
          , loopEvent = noApplicationEvents
          , loopUpdate = \_ → do
              -- A worker admits during the final update and is left inside its
              -- failing post.
              _ ← forkIO (submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= putMVar submitted)
              takeMVar held
              duringUpdate ← readIORef warnings
              -- The post is released only once the owner is waiting for it at
              -- the runner's own boundary, after quiescence and the drain.
              _ ← forkIO (awaitBlockedOnSTM owner >> putMVar release ())
              pure (Finish (duringUpdate, submitted))
          }
  -- Nothing was written while the notification was still in flight.
  duringUpdate `shouldBe` []
  written ← readIORef warnings
  map (componentText . entryComponent) written `shouldBe` ["glfw.wake"]
  takeMVar admitted' >>= (`shouldSatisfy` \case SubmitAccepted _ → True; _ → False)
  posts seam `shouldReturn` 1

-- | A loop that ends by raising still claims the report, and the failure it
-- raised stays primary.
testDegradationReportedOnFailingExit ∷ Expectation
testDegradationReportedOnFailingExit = do
  seam ←
    newSeam
      defaultScript {scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 "scripted wake failure"}
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (<> [entry])))
  (broken, _) ←
    caughtAs $
      hosted seam (settings [windowNamed "failing"]) (\host _ → pure host) $ \host control → do
        window ← onlyWindow host
        runOwnerLoop host control $
          LoopHooks
            { loopLogger = capturing
            , loopEvent = noApplicationEvents
            , loopUpdate = \_ → do
                _ ← submitWindowCommand (hostCommandPort host) [] (observeOf window)
                throwIO (Broken "the update failed")
            }
  broken `shouldBe` Broken "the update failed"
  written ← readIORef warnings
  map (componentText . entryComponent) written `shouldBe` ["glfw.wake"]

-- | The ordinary runner's own boundary reports a degradation begun after the
-- loop returned. The example makes no reporting call and quiesces nothing
-- itself: the managed lifetime does both, after the drain and while the
-- dependencies and the logger are still live.
testRunnerReportsWithoutBeingAsked ∷ Expectation
testRunnerReportsWithoutBeingAsked = do
  seam ← newSeam (failingPostScript "scripted wake failure")
  warnings ← newIORef ([] ∷ [LogEntry])
  ticket ←
    hostedLogging (recordingLogger warnings) seam (settings [windowNamed "unasked"]) (\host _ → pure host) $
      \host control → do
        window ← onlyWindow host
        runOwnerLoop host control $
          LoopHooks
            { loopLogger = quietLogger
            , loopEvent = noApplicationEvents
            , loopUpdate = \_ → pure (Finish ())
            }
        -- The loop has ended, and this admission's wake is the one that fails.
        queued ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
        readIORef warnings `shouldReturn` []
        pure queued
  warningComponents warnings `shouldReturn` ["glfw.wake"]
  settledExactlyOnce ticket `shouldReturn` NotExecuted

-- | Which committed operation is held between its commit and its wake.
data HeldOperation = AdmittedCommand | PublishedDemand
  deriving (Eq, Show)

-- | An operation paused immediately after its transaction committed: the
-- obligation it registered there is already visible, and its wake has not been
-- made. The runner's boundary waits for that obligation before it reports, so
-- the degradation the wake then causes is still reported.
--
-- The application starts no worker, so the only place its thread blocks in a
-- transaction after the action returns is that boundary. Were the boundary not
-- to wait, its attempt would find the path healthy and the run would end with
-- no warning at all.
testObligationHeldAfterCommit ∷ HeldOperation → Expectation
testObligationHeldAfterCommit operation = do
  seam ← newSeam (failingPostScript "scripted wake failure")
  warnings ← newIORef ([] ∷ [LogEntry])
  committed ← newEmptyMVar
  release ← newEmptyMVar
  (outstanding, duringAction) ←
    hostedLogging (recordingLogger warnings) seam (settings [windowNamed "held"]) (\host _ → pure host) $
      \host control → do
        window ← onlyWindow host
        runOwnerLoop host control $
          LoopHooks
            { loopLogger = quietLogger
            , loopEvent = noApplicationEvents
            , loopUpdate = \_ → pure (Finish ())
            }
        owner ← myThreadId
        _ ← forkIO $ case operation of
          AdmittedCommand → do
            let hooks = noAdmissionHooks {afterAdmission = putMVar committed () >> takeMVar release}
            void (submitWith hooks (hostCommandPort host) [] (observeOf window))
          PublishedDemand → do
            let hooks = noDemandHooks {afterPublication = putMVar committed () >> takeMVar release}
            void (publishDemandWith hooks (hostDemandPublisher host) immediateDemand)
        takeMVar committed
        -- Committed, so the obligation is registered; the wake has not been
        -- made, so nothing has degraded and nothing has been written.
        outstanding ← atomically (hostNotificationsInFlight host)
        duringAction ← readIORef warnings
        _ ← forkIO (awaitBlockedOnSTM owner >> putMVar release ())
        pure (outstanding, duringAction)
  outstanding `shouldBe` 1
  duringAction `shouldBe` []
  warningComponents warnings `shouldReturn` ["glfw.wake"]

-- | The report is made on every exit the runner has: a startup failure, an
-- action failure, and a cancellation, each keeping its own failure primary.
testReportsOnEveryExit ∷ Expectation
testReportsOnEveryExit = do
  -- A startup that degrades the wake path and then fails.
  startupSeam ← newSeam (failingPostScript "scripted wake failure")
  startupWarnings ← newIORef ([] ∷ [LogEntry])
  (startupFailure, _) ←
    caughtAs $
      hostedLogging (recordingLogger startupWarnings) startupSeam (settings [windowNamed "startup"])
        (\host _ → degradeWakePath host >> throwIO (Broken "the startup failed"))
        (\_ _ → pure ())
  startupFailure `shouldBe` Broken "the startup failed"
  wakeWarnings startupWarnings `shouldReturn` ["glfw.wake"]
  -- The startup's own failure is still the run's, reported as usual beside it.
  warningComponents startupWarnings `shouldReturn` ["glfw.wake", "runtime"]

  -- An action that degrades the wake path and then fails.
  actionSeam ← newSeam (failingPostScript "scripted wake failure")
  actionWarnings ← newIORef ([] ∷ [LogEntry])
  (actionFailure, _) ←
    caughtAs $
      hostedLogging (recordingLogger actionWarnings) actionSeam (settings [windowNamed "action"])
        (\host _ → pure host)
        (\host _ → degradeWakePath host >> throwIO (Broken "the action failed"))
  actionFailure `shouldBe` Broken "the action failed"
  wakeWarnings actionWarnings `shouldReturn` ["glfw.wake"]
  warningComponents actionWarnings `shouldReturn` ["glfw.wake", "runtime"]

  -- A run cancelled after it has degraded the wake path.
  cancelledSeam ← newSeam (failingPostScript "scripted wake failure")
  cancelledWarnings ← newIORef ([] ∷ [LogEntry])
  degraded ← newEmptyMVar
  never ← newEmptyMVar
  (runner, finished) ←
    onMainThread cancelledSeam $
      runWindowApplication
        (withLoggingLifetime (recordingLogger cancelledWarnings))
        "host-example"
        (hostOver cancelledSeam (settings [windowNamed "cancelled"]))
        id
        (\host _ → pure host)
        (\host _ → degradeWakePath host >> putMVar degraded () >> takeMVar never)
  takeMVar degraded
  killThread runner
  cancelled ← takeMVar finished
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  -- A cancelled run makes no terminal report, and the wake path's own is still
  -- written.
  warningComponents cancelledWarnings `shouldReturn` ["glfw.wake"]

-- | A worker that publishes demand until its stop request arrives, so
-- obligations keep being registered for as long as the application runs.
publishingUntilStopped ∷ WindowHost → MVar () → WorkerDefinition ()
publishingUntilStopped host published =
  workerDefinition "publishing" (\_ → pure ()) (\token () → keepPublishing token)
  where
    keepPublishing token = do
      stopping ← atomically ((True <$ awaitStopRequest token) `orElse` pure False)
      unless stopping $ do
        _ ← publishDemand (hostDemandPublisher host) immediateDemand
        -- The first publication is announced, so an example can wait for the
        -- degradation it caused rather than race it.
        _ ← tryPutMVar published ()
        yield
        keepPublishing token

-- | A run whose worker publishes until supervision stops it. The loop's own
-- boundary must not wait for obligations, because this worker keeps registering
-- them until the quiescence and drain that only the loop's result can reach; a
-- boundary that waited there would deadlock the shutdown. The run ends, on a
-- finish and on a cancellation, and the one report is still made.
testPublisherUntilStopped ∷ Expectation
testPublisherUntilStopped = do
  seam ← newSeam (failingPostScript "scripted wake failure")
  warnings ← newIORef ([] ∷ [LogEntry])
  published ← newEmptyMVar
  hostedLogging
    (recordingLogger warnings)
    seam
    (settings [windowNamed "publishing"])
    ( \host control →
        startSupervised control (required Service) (publishingUntilStopped host published) >>= expectStarted >> pure host
    )
    (\host control → readMVar published >> runOwnerLoop host control (turningUntil (recordingLogger warnings) 3))
  warningComponents warnings `shouldReturn` ["glfw.wake"]

  cancelledSeam ← newSeam (failingPostScript "scripted wake failure")
  cancelledWarnings ← newIORef ([] ∷ [LogEntry])
  turning ← newEmptyMVar
  never ← newEmptyMVar
  publishedAgain ← newEmptyMVar
  (runner, finished) ←
    onMainThread cancelledSeam $
      runWindowApplication
        (withLoggingLifetime (recordingLogger cancelledWarnings))
        "host-example"
        (hostOver cancelledSeam (settings [windowNamed "publishing"]))
        id
        ( \host control →
            startSupervised control (required Service) (publishingUntilStopped host publishedAgain)
              >>= expectStarted
              >> pure host
        )
        ( \host control → do
            readMVar publishedAgain
            runOwnerLoop host control (turningUntil (recordingLogger cancelledWarnings) 3)
            putMVar turning ()
            takeMVar never
        )
  takeMVar turning
  killThread runner
  cancelled ← takeMVar finished
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  warningComponents cancelledWarnings `shouldReturn` ["glfw.wake"]

-- | Turn until the numbered turn, then finish, writing through the given
-- logger. Which boundary claims the wake path's report depends on when the
-- degradation happened, so an example that asserts on it injects the same
-- logger here as the run's own.
turningUntil ∷ Logger → Natural → LoopHooks ()
turningUntil logger final =
  LoopHooks
    { loopLogger = logger
    , loopEvent = noApplicationEvents
    , loopUpdate = \turn → pure (if turnNumber turn == final then Finish () else Continue)
    }

-- | A run cancelled while its final boundary is waiting for a notification that
-- is still inside its failing post. The cancellation stays the run's failure,
-- and the degradation that post records afterwards is still reported: the wait
-- is completed uninterruptibly and the one attempt is spent before the
-- cancellation is re-raised.
testCancelledDuringTheFinalWait ∷ Expectation
testCancelledDuringTheFinalWait = do
  inside ← newEmptyMVar
  release ← newEmptyMVar
  firstPost ← newIORef True
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            reportError reporter 0x00010008 "scripted wake failure"
            first ← atomicModifyIORef' firstPost (\flag → (False, flag))
            when first (putMVar inside () >> takeMVar release)
        }
  warnings ← newIORef ([] ∷ [LogEntry])
  (runner, finished) ←
    onMainThread seam $
      runWindowApplication
        (withLoggingLifetime (recordingLogger warnings))
        "host-example"
        (hostOver seam (settings [windowNamed "cancelled wait"]))
        id
        (\host _ → pure host)
        ( \host _ → do
            window ← onlyWindow host
            -- A worker's admission commits, registering its obligation, and
            -- stays inside its failing post. The action then returns, so the
            -- runner's boundary waits for that obligation.
            _ ← forkIO (void (submitWindowCommand (hostCommandPort host) [] (observeOf window)))
            takeMVar inside
        )
  -- The boundary is waiting for the obligation; cancel it there.
  awaitBlockedOnSTM runner
  duringWait ← readIORef warnings
  killThread runner
  putMVar release ()
  cancelled ← takeMVar finished
  duringWait `shouldBe` []
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  warningComponents warnings `shouldReturn` ["glfw.wake"]

-- | A cancellation requested at the instant the action returns. It lands in the
-- tail of the action, in the handoff to the reporting attempt, inside the
-- attempt's own write, or after the run has already finished — the rounds
-- sample all of it. The handoff is masked and the attempt is claimed before
-- anything it could be delivered at, so wherever it lands the one report is
-- still made and the run ends either cancelled or complete, never some other
-- failure.
testCancelledAsTheActionReturns ∷ Expectation
testCancelledAsTheActionReturns = do
  outcomes ← mapM (const oneRound) [1 .. 10 ∷ Int]
  map snd outcomes `shouldBe` replicate 10 ["glfw.wake"]
  map fst outcomes `shouldSatisfy` all id
  where
    oneRound = do
      seam ← newSeam (failingPostScript "scripted wake failure")
      warnings ← newIORef ([] ∷ [LogEntry])
      returning ← newEmptyMVar
      (runner, finished) ←
        onMainThread seam $
          runWindowApplication
            (withLoggingLifetime (recordingLogger warnings))
            "host-example"
            (hostOver seam (settings [windowNamed "returning"]))
            id
            (\host _ → pure host)
            (\host _ → degradeWakePath host >> putMVar returning ())
      -- Requested as the action's last act, so its delivery races the handoff.
      takeMVar returning
      _ ← forkIO (throwTo runner ThreadKilled)
      outcome ← takeMVar finished
      recorded ← warningComponents warnings
      -- Cancelled, or finished before the cancellation could land; nothing else.
      pure (either (\caught → fromException caught == Just ThreadKilled) (const True) outcome, recorded)

-- | An application that owns its own shutdown and calls
-- 'reportHostWakeDegradation' itself: a cancellation at that boundary's wait
-- completes the wait, spends the attempt, and propagates.
testCancelledDuringACustomShutdown ∷ Expectation
testCancelledDuringACustomShutdown = do
  inside ← newEmptyMVar
  release ← newEmptyMVar
  firstPost ← newIORef True
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            reportError reporter 0x00010008 "scripted wake failure"
            first ← atomicModifyIORef' firstPost (\flag → (False, flag))
            when first (putMVar inside () >> takeMVar release)
        }
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = recordingLogger warnings
  (runner, finished) ←
    onMainThread seam $
      runWindowApplication
        (withLoggingLifetime quietLogger)
        "host-example"
        (hostOver seam (settings [windowNamed "custom"]))
        id
        (\host _ → pure host)
        ( \host _ → do
            window ← onlyWindow host
            _ ← forkIO (void (submitWindowCommand (hostCommandPort host) [] (observeOf window)))
            takeMVar inside
            -- The application's own boundary, with the obligation still in its
            -- post: this call waits for it.
            void (reportHostWakeDegradation capturing host)
        )
  awaitBlockedOnSTM runner
  duringWait ← readIORef warnings
  killThread runner
  putMVar release ()
  cancelled ← takeMVar finished
  duringWait `shouldBe` []
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  warningComponents warnings `shouldReturn` ["glfw.wake"]

-- | Admit one command, whose wake fails and degrades the session's wake path.
degradeWakePath ∷ WindowHost → IO ()
degradeWakePath host = do
  window ← onlyWindow host
  void (submitWindowCommand (hostCommandPort host) [] (observeOf window))

-- | The reporting attempt is ordinary interruptible work on the calling thread,
-- not part of a release: a cancellation delivered while its sink is running
-- reaches it, ends the attempt, and propagates, and the attempt is not retried.
testReportingIsInterruptible ∷ Expectation
testReportingIsInterruptible = do
  seam ← newSeam (failingPostScript "scripted wake failure")
  reached ← newEmptyMVar
  never ← newEmptyMVar
  attempts ← newIORef (0 ∷ Int)
  let holding =
        mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \_ → do
          modifyIORef' attempts (+ 1)
          putMVar reached ()
          takeMVar never
  (runner, finished) ←
    onMainThread seam $
      runWindowApplication
        (withLoggingLifetime holding)
        "host-example"
        (hostOver seam (settings [windowNamed "interruptible"]))
        id
        (\host _ → pure host)
        (\host _ → degradeWakePath host)
  -- The run has ended its action; the boundary's attempt is inside the sink.
  takeMVar reached
  killThread runner
  cancelled ← takeMVar finished
  either (Just . fromException) (const Nothing) cancelled `shouldBe` Just (Just ThreadKilled)
  -- One attempt, spent by the cancellation and never retried.
  readIORef attempts `shouldReturn` 1

-- | A degradation begun after the loop returned, while admission is still open:
-- the loop cannot claim it, and the application's own boundary after quiescence
-- does.
testDegradationAfterTheLoop ∷ Expectation
testDegradationAfterTheLoop = do
  seam ←
    newSeam
      defaultScript {scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 "scripted wake failure"}
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (<> [entry])))
  (afterLoop, attempt, again) ←
    hosted seam (settings [windowNamed "after"]) (\host _ → pure host) $ \host control → do
      window ← onlyWindow host
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = capturing
          , loopEvent = noApplicationEvents
          , loopUpdate = \_ → pure (Finish ())
          }
      -- Nothing degraded while the loop ran, so it wrote nothing.
      readIORef warnings `shouldReturn` []
      _ ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
      afterLoop ← atomically (hostWakePath host)
      atomically (quiesceWindowHost host)
      attempt ← reportHostWakeDegradation capturing host
      again ← reportHostWakeDegradation capturing host
      pure (afterLoop, attempt, again)
  afterLoop `shouldSatisfy` \case
    WakePathDegraded _ DegradationOwed → True
    _ → False
  attempt `shouldBe` DegradationReportAttempted
  again `shouldBe` NoDegradationDue
  written ← readIORef warnings
  map (componentText . entryComponent) written `shouldBe` ["glfw.wake"]

-- | The last turn is the one that degrades the path: its update submits a
-- command whose wake fails and finishes the loop at once. The report is still
-- claimed before that turn ends, rather than left owed to a loop that has
-- already returned.
testDegradationOnTheFinalTurn ∷ Expectation
testDegradationOnTheFinalTurn = do
  seam ←
    newSeam
      defaultScript {scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 "scripted wake failure"}
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (<> [entry])))
  (ticket, duringUpdate) ←
    hosted seam (settings [windowNamed "late"]) (\host _ → pure host) $ \host control → do
      window ← onlyWindow host
      runOwnerLoop host control $
        LoopHooks
          { loopLogger = capturing
          , loopEvent = noApplicationEvents
          , loopUpdate = \_ → do
              queued ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
              -- Nothing was written yet: the degradation happened inside this
              -- update, after the turn's earlier reporting boundary.
              duringUpdate ← readIORef warnings
              pure (Finish (queued, duringUpdate))
          }
  duringUpdate `shouldBe` []
  written ← readIORef warnings
  map (componentText . entryComponent) written `shouldBe` ["glfw.wake"]
  -- The command the failed wake announced is untouched, and quiescence settles
  -- it exactly once.
  settledExactlyOnce ticket `shouldReturn` NotExecuted
  posts seam `shouldReturn` 1

-- | Two hosts in turn over one borrowed session: the first degrades the
-- session's wake path and writes its one warning, and the second, a separate
-- 'WindowHost' over the same session, inherits both.
testDegradationSharedByBorrowedHosts ∷ Expectation
testDegradationSharedByBorrowedHosts = do
  seam ←
    newSeam
      defaultScript {scriptPostEmptyEvent = \reporter → reportError reporter 0x00010008 "scripted wake failure"}
  warnings ← newIORef ([] ∷ [LogEntry])
  let capturing = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' warnings (<> [entry])))
      -- The session outlives both hosts, because neither owns its scope.
      borrowed session = allocWindowHostIn (pure session) (settings [windowNamed "borrowed"])
      application session name =
        runWindowApplication lifetime name (borrowed session) id (\host _ → pure host) $ \host control → do
          window ← onlyWindow host
          ticket ← submitWindowCommand (hostCommandPort host) [] (observeOf window) >>= admitted
          runOwnerLoop host control $
            LoopHooks
              { loopLogger = capturing
              , loopEvent = noApplicationEvents
              , loopUpdate = \turn → pure (if turnNumber turn == 2 then Finish () else Continue)
              }
          settledExactlyOnce ticket
  (dispositions, stillWaking) ← asProcessMainThread seam $ entered seam $ \session → do
    firstHost ← application session "borrowed-host-first"
    secondHost ← application session "borrowed-host-second"
    -- Neither host's shutdown closed the session's own wake capability: the
    -- session outlives them both, and a wake still enters the library.
    stillWaking ← wakeSession (sessionWake session)
    pure ([firstHost, secondHost], stillWaking)
  stillWaking `shouldSatisfy` (/= WakeTerminal)
  -- Each host's admitted command settled exactly once through its own loop.
  dispositions `shouldSatisfy` all (\case Performed (ObservationPublished _ _) → True; _ → False)
  written ← readIORef warnings
  -- One warning across both hosts, and only the first host's admission entered
  -- the library: the second skipped the degraded path, and the remaining post is
  -- the example's own wake through the session's still-open capability.
  map (componentText . entryComponent) written `shouldBe` ["glfw.wake"]
  posts seam `shouldReturn` 2

-- | A construction that rolls back hands no capability to anyone, so nothing
-- can be admitted or published through a half-built host, and nothing wakes.
testRollbackLendsNothing ∷ Expectation
testRollbackLendsNothing = do
  seam ← newSeam defaultScript
  started ← newIORef False
  (rejection, _) ←
    caughtAs $
      hosted seam (settings [windowNamed "built", windowNamed "bad\NUL"]) (\_ _ → writeIORef started True) (\_ _ → pure ())
  rejection `shouldBe` WindowTitleRejected
  readIORef started `shouldReturn` False
  posts seam `shouldReturn` 0

windowClient ∷ WindowHost → Window → IO WindowClient
windowClient host window =
  atomically (hostWindowClient host (windowIdentity window)) >>= maybe (unexpected "the host window has no client") pure

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
                { loopLogger = quietLogger
                , loopEvent = do
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
lifetime = withLoggingLifetime quietLogger

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

hostOver ∷ Seam → HostConfig → Scoped WindowHost
hostOver seam = allocWindowHostIn (seamSession seam defaultSessionConfig)

-- | Run an application over a host in the seam's session, on a bound thread
-- designated as the process main thread.
hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hosted = hostedLogging quietLogger

-- | 'hosted' over a logging lifetime carrying the example's own logger, so an
-- example sees what the runner's own boundaries write, not only what it passes
-- to 'LoopHooks'.
hostedLogging
  ∷ Logger → Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hostedLogging logger seam config startup action =
  asProcessMainThread
    seam
    (runWindowApplication (withLoggingLifetime logger) "host-example" (hostOver seam config) id startup action)

-- | A logger that records what it is given, for an example that asserts on the
-- entries a boundary wrote.
recordingLogger ∷ IORef [LogEntry] → Logger
recordingLogger entries =
  mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' entries (<> [entry])))

-- | The components of the entries an example's logger recorded.
warningComponents ∷ IORef [LogEntry] → IO [Text]
warningComponents entries = map (componentText . entryComponent) <$> readIORef entries

-- | Only the wake path's own entries, so an example can assert on them beside
-- whatever else a failing run's terminal report writes through the same logger.
wakeWarnings ∷ IORef [LogEntry] → IO [Text]
wakeWarnings entries = filter (== "glfw.wake") <$> warningComponents entries

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
