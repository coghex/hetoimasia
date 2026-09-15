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
module Test.GLFW.Native.Host (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, orElse, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Component, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
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
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

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
                  { loopEvent = noApplicationEvents
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
                  { loopEvent = noApplicationEvents
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
                    { loopEvent = noApplicationEvents
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
lifetime = withLoggingLifetime (mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ())))

settings ∷ Text → HostConfig
settings name = (defaultHostConfig [hiddenTestWindowConfig name 160 120]) {hostIdleWait = 0.1}

onlyWindow ∷ WindowHost → IO Window
onlyWindow host = case hostWindows host of
  [window] → pure window
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
