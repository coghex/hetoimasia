-- | The window host and its owner loop over the real shared session.
--
-- Each example runs a whole application through
-- 'Hetoimasia.Runtime.GLFW.runWindowApplication' inside one dispatched
-- operation, so the owner loop runs on the process main thread that owns the
-- shared session, and supervised workers run beside it. The host is built over
-- that session with 'allocWindowHostIn', so it borrows the session rather than
-- owning it: its release closes admission and destroys its own window, and the
-- fixture keeps the session. No example sleeps; a worker coordinates with the
-- loop through STM, and every loop is bounded in turns.
--
-- The dynamic window examples build the host with no windows or a few, create
-- and close windows through the loop, and read each window's terminal phase from
-- the observations its client capabilities carry.
module Test.GLFW.Native.Host (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, orElse, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (Exception, throwIO, try)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Component, Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotReader, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocResource)
import Hetoimasia.Foundation.Worker (StopToken, WorkerDefinition, awaitStopRequest, workerDefinition)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Native (noteProgressForCheck, requestCloseForCheck, takeWaitNotedForCheck)
import Hetoimasia.GLFW.Internal.Window (windowNativeHandle)
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (..)
  , Role (..)
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , startSupervised
  , workerStatus
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Numeric.Natural (Natural)
import Test.GLFW.Native.Support (Shared, currentObservation, failed, owned)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Shared → Spec
spec shared = describe "window host" $ do
  it "settles an observation request through the real owner loop with a published revision" $ do
    (settled, window, revision) ←
      owned shared $ \session → do
        result ← newTVarIO Nothing
        runWindowApplication lifetime "native host" (allocWindowHostIn (pure session) (settings "observed")) id
          ( \host control → do
              window ← onlyWindow host
              _ ← startSupervised control (required Service) (observer host window result) >>= expectStarted
              pure host
          )
          ( \host control →
              runOwnerLoop host control $
                LoopHooks
                  { loopLogger = quietLogger
                  , loopEvent = noApplicationEvents
                  , loopUpdate = \turn →
                      readTVarIO result >>= \case
                        Just (settled, revision) → do
                          window ← onlyWindow host
                          pure (Finish (settled, windowIdentity window, revision))
                        Nothing
                          | turnNumber turn >= turnBound → failed "the worker's request did not settle within the turn bound"
                          | otherwise → pure Continue
                  }
          )
    -- Publication commits before settlement, so the revision the worker read
    -- with the settlement is at least the one the command published.
    settled `shouldSatisfy` \case
      Just (Performed (ObservationPublished published publishedRevision)) →
        published == window && publishedRevision <= revision
      _ → False

  it "lets a supervised worker progress while the owner is blocked inside the production native wait" $ do
    waits ←
      owned shared $ \session → do
        confirmed ← newTVarIO False
        waited ← newIORef (0 ∷ Int)
        runWindowApplication lifetime "native host" (allocWindowHostIn (pure session) (settings "waiting") {hostIdleWait = 1}) id
          (\host control → startSupervised control (required Service) (notingInsideWait host confirmed) >>= expectStarted >> pure host)
          ( \host control →
              runOwnerLoop host control $
                LoopHooks
                  { loopLogger = quietLogger
                  , loopEvent = noApplicationEvents
                  , loopUpdate = \turn → do
                      noted ←
                        if turnWaited turn
                          then modifyIORef' waited (+ 1) >> takeWaitNotedForCheck
                          else pure False
                      if noted
                        then atomically (writeTVar confirmed True) >> Finish <$> readIORef waited
                        else
                          if turnNumber turn >= turnBound
                            then failed "no progress landed inside a production native wait within the turn bound"
                            else pure Continue
                  }
          )
    waits `shouldSatisfy` (>= 1)

  it "surfaces a real native close request to application policy without destroying the window, keeps the runtime running, and releases the host only after the drain" $ do
    (request, window, (endedAtSurface, phaseAtSurface, liveAfter), releasedWhileLive, endedAfter, finalPhase) ←
      owned shared $ \session → do
        held ← newIORef Nothing
        releasedLive ← newIORef Nothing
        surfacedAt ← newIORef Nothing
        (request, observed) ←
          runWindowApplication lifetime "native host" (allocWindowHostIn (pure session) (settings "closed")) id
            ( \host control → do
                window ← onlyWindow host
                writeIORef held (Just window)
                service ← startSupervised control (required Service) (watching window releasedLive) >>= expectStarted
                pure (host, service)
            )
            ( \(host, service) control → do
                window ← onlyWindow host
                runOwnerLoop host control $
                  LoopHooks
                    { loopLogger = quietLogger
                    , loopEvent = noApplicationEvents
                    , loopUpdate = \turn → do
                        when (turnNumber turn == 1) (requestCloseForCheck (windowNativeHandle window))
                        policy surfacedAt service window turn
                    }
            )
        window ← readIORef held >>= maybe (failed "no window was built") pure
        releasedWhileLive ← readIORef releasedLive
        endedAfter ← windowEnded window
        final ← currentObservation window
        pure (request, windowIdentity window, observed, releasedWhileLive, endedAfter, observedPhase final)
    closeRequestWindow request `shouldBe` window
    endedAtSurface `shouldBe` False
    phaseAtSurface `shouldBe` WindowOpen
    liveAfter `shouldBe` True
    releasedWhileLive `shouldBe` Just True
    endedAfter `shouldBe` True
    finalPhase `shouldBe` WindowReleased

  describe "dynamic windows" $ do
    it "creates three windows through a worker's requests and closes them in the order B, A, C, the others still observing and executing" $
      testCloseOrder shared [1, 0, 2]
    it "creates three windows through a worker's requests and closes them in the order C, A, B, the others still observing and executing" $
      testCloseOrder shared [2, 0, 1]
    it "closes a window while a worker holds its port, which then answers closed while another window still executes" $
      testHeldPortClosed shared
    it "honours a real native close request through the close protocol, leaving the other window open" $
      testHonouredCloseRequest shared
    it "disposes every remaining window, a created one included, only after the drain and with no retained cleanup failure" $
      testRemainingDisposedAfterDrain shared

-- ---------------------------------------------------------------------------
-- Dynamic windows

-- | What one close in a worker's sequence produced: the close's settlement, the
-- closed window's phase right after it, and the observations requested through
-- every window still open.
type CloseStep = (Disposition, WindowPhase, [Disposition])

testCloseOrder ∷ Shared → [Int] → Expectation
testCloseOrder shared order = do
  report ←
    owned shared $ \session → do
      result ← newTVarIO Nothing
      outcome ←
        runWindowApplication lifetime "native dynamic" (allocWindowHostIn (pure session) (dynamicSettings [])) id
          (\host control → startSupervised control (required Service) (creatingAndClosing host order result) >>= expectStarted >> pure host)
          (\host control → runOwnerLoop host control (untilReported result))
      case outcome of
        Left message → pure (Left message)
        Right (readers, steps) → Right . (steps,) <$> mapM readerPhase readers
  case report of
    Left message → expectationFailure message
    Right (steps, finals) → do
      map (\(_, _, observed) → length observed) steps `shouldBe` [2, 1, 0]
      forM_ steps $ \(closed, phase, observed) → do
        closed `shouldSatisfy` \case
          Performed (WindowCloseBegun _) → True
          _ → False
        phase `shouldBe` WindowReleased
        observed `shouldSatisfy` all performedObservation
      finals `shouldBe` replicate 3 WindowReleased

-- | A service that creates three windows through the host's port, closes them
-- in the given order, and after each close observes every window still open
-- through that window's own port, then runs until stopped.
creatingAndClosing
  ∷ WindowHost
  → [Int]
  → TVar (Maybe (Either String ([SnapshotReader WindowObservation], [CloseStep])))
  → WorkerDefinition ()
creatingAndClosing host order result =
  workerDefinition "creating and closing" (\_ → pure ()) $ \token () → do
    outcome ← try $ do
      created ← forM ["first", "second", "third"] $ \name → do
        (_, ticket) ← settleRequest token (hostCommandPort host) (createWindowCommand (hiddenTestWindowConfig name 160 120))
        atomically (pollWindowClient ticket) >>= maybe (throwIO (Stopped "a creation handed nothing over")) pure
      steps ← forM (zip [1 ..] order) $ \(position, index) → do
        let closing = created !! index
            closedSoFar = take position order
        (closed, _) ← settleRequest token (hostCommandPort host) (closeWindowCommand (clientWindow closing))
        phase ← readerPhase (clientObservations closing)
        observed ←
          forM [client | (candidate, client) ← zip [0 ..] created, candidate `notElem` closedSoFar] $ \client →
            fst <$> settleRequest token (clientCommandPort client) (observeWindowCommand (clientWindow client))
        pure (closed, phase, observed)
      pure (map clientObservations created, steps)
    atomically (writeTVar result (Just (either (\(Stopped message) → Left message) Right outcome)))
    untilStopped token

testHeldPortClosed ∷ Shared → Expectation
testHeldPortClosed shared = do
  report ←
    owned shared $ \session → do
      holding ← newTVarIO False
      closed ← newTVarIO False
      result ← newTVarIO Nothing
      runWindowApplication lifetime "native dynamic" (allocWindowHostIn (pure session) (dynamicSettings ["kept", "held"])) id
        ( \host control → do
            (kept, held) ← twoClients host
            _ ← startSupervised control (required Service) (holdingPort kept held holding closed result) >>= expectStarted
            pure (host, held)
        )
        ( \(host, held) control →
            runOwnerLoop host control $
              LoopHooks
                { loopLogger = quietLogger
                , loopEvent = noApplicationEvents
                , loopUpdate = \turn → do
                    ready ← readTVarIO holding
                    already ← readTVarIO closed
                    when (ready && not already) $ do
                      started ← closeHostWindow host (clientWindow held)
                      unless (started == CloseStarted) (failed ("the held window's close answered " <> show started))
                      atomically (writeTVar closed True)
                    untilReported result `loopUpdate` turn
                }
        )
  case report of
    Left message → expectationFailure message
    Right (answer, phase, other) → do
      answer `shouldBe` SubmitClosed
      phase `shouldBe` WindowReleased
      other `shouldSatisfy` performedObservation

-- | A service that holds a window's port, signals that it does, and once the
-- owner has closed that window submits through the retained port, reads the
-- window's phase, and requests an observation of another window through that
-- window's own port.
holdingPort
  ∷ WindowClient
  → WindowClient
  → TVar Bool
  → TVar Bool
  → TVar (Maybe (Either String (SubmitResult, WindowPhase, Disposition)))
  → WorkerDefinition ()
holdingPort kept held holding closed result =
  workerDefinition "holding" (\_ → pure ()) $ \token () → do
    atomically (writeTVar holding True)
    proceed ← atomically ((True <$ (readTVar closed >>= check)) `orElse` (False <$ awaitStopRequest token))
    when proceed $ do
      answer ← submitWindowCommand (clientCommandPort held) [("client", "holding")] (observeWindowCommand (clientWindow held))
      phase ← readerPhase (clientObservations held)
      other ← try (fst <$> settleRequest token (clientCommandPort kept) (observeWindowCommand (clientWindow kept)))
      atomically (writeTVar result (Just (either (\(Stopped message) → Left message) (\settled → Right (answer, phase, settled)) other)))
    untilStopped token

testHonouredCloseRequest ∷ Shared → Expectation
testHonouredCloseRequest shared = do
  (honoured, onlyKept, closingPhase, keptPhase) ←
    owned shared $ \session →
      runWindowApplication lifetime "native dynamic" (allocWindowHostIn (pure session) (dynamicSettings ["closing", "kept"])) id (\host _ → pure host) $ \host control → do
        (closing, kept) ← twoClients host
        answered ← newIORef Nothing
        runOwnerLoop host control $
          LoopHooks
            { loopLogger = quietLogger
            , loopEvent = noApplicationEvents
            , loopUpdate = \turn → do
                when (turnNumber turn == 1) $
                  void (withHostWindow host (clientWindow closing) (requestCloseForCheck . windowNativeHandle))
                readIORef answered >>= \case
                  Nothing → case [request | request ← turnCloseRequests turn, closeRequestWindow request == clientWindow closing] of
                    request : _ → do
                      honourHostCloseRequest host request >>= writeIORef answered . Just
                      pure Continue
                    []
                      | turnNumber turn >= turnBound → failed "no native close request reached the application within the turn bound"
                      | otherwise → pure Continue
                  Just answer → do
                    listed ← atomically (hostWindowIdentities host)
                    closingPhase ← readerPhase (clientObservations closing)
                    keptPhase ← readerPhase (clientObservations kept)
                    pure (Finish (answer, listed == [clientWindow kept], closingPhase, keptPhase))
            }
  honoured `shouldBe` CloseStarted
  onlyKept `shouldBe` True
  closingPhase `shouldBe` WindowReleased
  keptPhase `shouldBe` WindowOpen

testRemainingDisposedAfterDrain ∷ Shared → Expectation
testRemainingDisposedAfterDrain shared = do
  (atDrain, finals) ←
    owned shared $ \session → do
      held ← newIORef []
      journal ← newTVarIO Nothing
      readers ←
        runWindowApplication lifetime "native dynamic" (allocWindowHostIn (pure session) (dynamicSettings ["first", "second"])) id
          (\host control → startSupervised control (required Service) (phasesAtRelease held journal) >>= expectStarted >> pure host)
          ( \host control → do
              requested ← newIORef Nothing
              runOwnerLoop host control $
                LoopHooks
                  { loopLogger = quietLogger
                  , loopEvent = noApplicationEvents
                  , loopUpdate = \turn →
                      readIORef requested >>= \case
                        Nothing →
                          submitWindowCommand (hostCommandPort host) [] (createWindowCommand (hiddenTestWindowConfig "created" 160 120)) >>= \case
                            SubmitAccepted ticket → writeIORef requested (Just ticket) >> pure Continue
                            other → failed ("the creation was not admitted: " <> show other)
                        Just ticket →
                          atomically (pollWindowClient ticket) >>= \case
                            Nothing
                              | turnNumber turn >= turnBound → failed "the creation did not settle within the turn bound"
                              | otherwise → pure Continue
                            Just _ → do
                              listed ← atomically (hostWindowIdentities host)
                              readers ← forM listed $ \window →
                                atomically (hostWindowClient host window) >>= maybe (failed "a listed window has no client") (pure . clientObservations)
                              writeIORef held readers
                              pure (Finish readers)
                  }
          )
      -- The run returned, so no cleanup failure was retained.
      (,) <$> readTVarIO journal <*> mapM readerPhase readers
  atDrain `shouldBe` Just (replicate 3 WindowOpen)
  finals `shouldBe` replicate 3 WindowReleased

-- | A service that runs until stopped and records, at its release, the phases
-- of the windows the owner stored for it.
phasesAtRelease ∷ IORef [SnapshotReader WindowObservation] → TVar (Maybe [WindowPhase]) → WorkerDefinition ()
phasesAtRelease held journal =
  workerDefinition
    "phases at release"
    (\_ → allocResource (pure ()) (\() → readIORef held >>= mapM readerPhase >>= atomically . writeTVar journal . Just))
    (\token () → untilStopped token)

-- | A worker's request ended before it settled.
newtype Stopped = Stopped String
  deriving (Show)

instance Exception Stopped

-- | Submit a command, waiting for capacity, and wait for its settlement composed
-- with the worker's stop request.
settleRequest ∷ StopToken → WindowCommandPort → WindowCommand → IO (Disposition, CompletionTicket)
settleRequest token port command =
  awaitSubmitWindowCommand port [("client", "native dynamic")] command >>= \case
    WaitClosed → throwIO (Stopped "admission closed before the request was admitted")
    WaitAccepted ticket →
      atomically ((Just <$> (pollCompletion ticket >>= maybe retry pure)) `orElse` (Nothing <$ awaitStopRequest token)) >>= \case
        Nothing → throwIO (Stopped "the worker was stopped before its request settled")
        Just settled → pure (settled, ticket)

-- | Finish with a worker's report once it has one, failing past the turn bound.
untilReported ∷ TVar (Maybe r) → LoopHooks r
untilReported result =
  LoopHooks
    { loopLogger = quietLogger
    , loopEvent = noApplicationEvents
    , loopUpdate = \turn →
        readTVarIO result >>= \case
          Just report → pure (Finish report)
          Nothing
            | turnNumber turn >= turnBound → failed "the worker did not report within the turn bound"
            | otherwise → pure Continue
    }

dynamicSettings ∷ [Text] → HostConfig
dynamicSettings names =
  (defaultHostConfig [hiddenTestWindowConfig name 160 120 | name ← names]) {hostWindowLimit = 3, hostIdleWait = 0.1}

-- | The client capabilities of the host's two windows, in creation order.
twoClients ∷ WindowHost → IO (WindowClient, WindowClient)
twoClients host =
  atomically (hostWindowIdentities host) >>= \case
    [first, second] → (,) <$> clientOf first <*> clientOf second
    windows → failed ("expected two windows, found " <> show (length windows))
  where
    clientOf window = atomically (hostWindowClient host window) >>= maybe (failed "a listed window has no client") pure

readerPhase ∷ SnapshotReader WindowObservation → IO WindowPhase
readerPhase reader = observedPhase . preparedValue . observedValue <$> atomically (readSnapshot reader)

performedObservation ∷ Disposition → Bool
performedObservation = \case
  Performed (ObservationPublished {}) → True
  _ → False

-- | The close policy: note the first surfaced request with what the window
-- looked like then, keep turning for two more turns, and finish with whether the
-- worker is still running. It never rejects or acts on the request.
policy
  ∷ IORef (Maybe (Natural, CloseRequest, Bool, WindowPhase))
  → SupervisedWorker ()
  → Window
  → Turn
  → IO (TurnStep (CloseRequest, (Bool, WindowPhase, Bool)))
policy surfacedAt service window turn =
  readIORef surfacedAt >>= \case
    Nothing → case turnCloseRequests turn of
      [request] → do
        ended ← windowEnded window
        observation ← currentObservation window
        writeIORef surfacedAt (Just (turnNumber turn, request, ended, observedPhase observation))
        pure Continue
      _
        | turnNumber turn >= turnBound → failed "no native close request reached the application within the turn bound"
        | otherwise → pure Continue
    Just (at, request, ended, phase)
      | turnNumber turn < at + 2 → pure Continue
      | otherwise → do
          status ← atomically (workerStatus service)
          pure (Finish (request, (ended, phase, isLive status)))

-- | A service that requests an observation, composing its wait with its stop
-- request, publishes the settlement with the revision it read beside it, and
-- runs until stopped.
observer ∷ WindowHost → Window → TVar (Maybe (Maybe Disposition, Natural)) → WorkerDefinition ()
observer host window result =
  workerDefinition "observer" (\_ → pure ()) $ \token () → do
    submitted ← awaitSubmitWindowCommand (hostCommandPort host) [("client", "native observer")] (observeWindowCommand (windowIdentity window))
    settled ← case submitted of
      WaitAccepted ticket → atomically (settlement ticket `orElse` ((Nothing, 0) <$ awaitStopRequest token))
      WaitClosed → pure (Nothing, 0)
    atomically (writeTVar result (Just settled))
    untilStopped token
  where
    settlement ticket = do
      disposition ← pollCompletion ticket >>= maybe retry pure
      observation ← readSnapshot (windowObservations window)
      pure (Just disposition, observedRevision (preparedValue (observedValue observation)))

-- | A service that, whenever the owner has begun or is about to begin a finite
-- wait, tries to record progress inside it until the owner confirms that a note
-- landed, then runs until stopped. Every wait is composed with its stop request.
notingInsideWait ∷ WindowHost → TVar Bool → WorkerDefinition ()
notingInsideWait host confirmed =
  workerDefinition "noting" (\_ → pure ()) $ \token () →
    let attempt = do
          next ←
            atomically $
              (Nothing <$ awaitStopRequest token)
                `orElse` (Just True <$ (readTVar confirmed >>= check))
                `orElse` (Just False <$ (hostActivity host >>= check . activityWaiting))
          case next of
            Nothing → pure ()
            Just True → untilStopped token
            Just False → noteProgressForCheck >> yield >> attempt
     in attempt

-- | A service that runs until stopped, and records at its release whether its
-- window was still live.
watching ∷ Window → IORef (Maybe Bool) → WorkerDefinition ()
watching window released =
  workerDefinition
    "watcher"
    (\_ → allocResource (pure ()) (\() → windowEnded window >>= writeIORef released . Just . not))
    (\token () → untilStopped token)

untilStopped ∷ StopToken → IO ()
untilStopped token = atomically (awaitStopRequest token)

-- | A logging lifetime whose records go nowhere.
lifetime ∷ (LoggingLifetime → IO r) → IO r
lifetime = withLoggingLifetime quietLogger

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

settings ∷ Text → HostConfig
settings name = (defaultHostConfig [hiddenTestWindowConfig name 160 120]) {hostIdleWait = 0.1}

-- | The host's only window, on the owner thread. It is taken out of its borrow
-- so an example can inspect its terminal state after the run; the examples only
-- read it.
onlyWindow ∷ WindowHost → IO Window
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] → withHostWindow host identity pure >>= \case
      WindowAvailable window → pure window
      WindowEnded _ → failed "the host's only window has ended"
    windows → failed ("expected one window, found " <> show (length windows))

required ∷ Role → WorkerPolicy
required role = WorkerPolicy role Supervision.Required testComponent (\_ → pure Unrecognized)

testComponent ∷ Component
testComponent = unsafeComponent "test.glfw-native.host"

expectStarted ∷ SupervisedStart r → IO (SupervisedWorker r)
expectStarted = \case
  WorkerStarted worker → pure worker
  WorkerStartUnavailable _ _ → failed "the worker was unavailable"
  WorkerStartRejected → failed "the worker's start was rejected"

isLive ∷ WorkerStatus → Bool
isLive WorkerLive = True
isLive _ = False

-- | The most turns an example waits for what it is waiting on. Idle turns wait at
-- most 0.1 seconds, or one second in the wait example, whose landed note wakes
-- the wait at once.
turnBound ∷ Natural
turnBound = 300
