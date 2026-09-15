-- | Examples for the window host's dynamic windows, over the test seam.
--
-- Each example runs a whole application through
-- 'Hetoimasia.Runtime.GLFW.runWindowApplication' on a thread the seam treats as
-- the process main thread, with a host built over a seam session. Creation,
-- per-window ports, the close protocol, the collection that owns the windows,
-- fair dispatch, and shutdown are the production code, and nothing initializes
-- GLFW. Commands are submitted from the owner's update opportunity and read
-- back on a later turn, so no example waits on its own loop.
--
-- Threads are coordinated with STM, IORefs, and 'threadStatus', never with a
-- sleep.
module Test.GLFW.Dynamic (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, yield)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (AsyncException (ThreadKilled), Exception, IOException, SomeException, displayException, throwIO, try)
import Control.Monad (forM, forM_, replicateM, unless, void, when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Log (Component, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (SnapshotCursor, SnapshotReader, Update (..), awaitSnapshot, observedCursor, observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocResource, cleanupFailureLabel, cleanupFailures)
import Hetoimasia.Foundation.Worker (WorkerDefinition, awaitStopRequest, workerDefinition)
import Hetoimasia.GLFW.Command
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , Seam
  , SeamScript (..)
  , WindowEvent (CloseRequested)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , reportError
  , seamCalls
  , seamLiveWindowCallbacks
  , seamQueueEvents
  , seamSession
  )
import Hetoimasia.GLFW.Session (NativeError (..), NativeFailure (..), NativeOutcome (..), ReportingThread (..), Reports (..), defaultSessionConfig)
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.GLFW.Internal (HostHooks (..), allocWindowHostWith, noHostHooks)
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (Recognition (..), Role (..), RuntimeControl, SupervisedStart (..), WorkerPolicy (..), startSupervised)
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Numeric.Natural (Natural)
import Test.GLFW.Window (boundedExample, caughtAs, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW dynamic windows" $ do
  describe "creation" $ do
    it "hands over a created window's port and observations beside its prepared completion, only after its initial observation, without creation or cross-window authority"
      (boundedExample testCreationHandoff)
    it "rejects creation beyond the live-window limit and an invalid configuration before any native effect"
      (boundedExample testCapacityRejection)
    it "rolls a failed construction back with its native evidence, registering nothing and consuming no capacity"
      (boundedExample testFailedCreationRollback)
    it "poisons creation after a rollback's own cleanup failure, retaining it through the host's final exit"
      (boundedExample testRollbackCleanupPoisons)
    it "keeps a window whose creation ticket nobody awaits enumerable, live through the drain, and disposed at shutdown"
      (boundedExample testDroppedCreationTicket)
    it "rolls back a construction cancelled from another thread, registering nothing, reclaiming its capacity, and handing nothing over"
      (boundedExample testCancelledConstruction)
    it "keeps a window registered and enumerable when a cancellation pending across its registration lands before its result is published"
      (boundedExample testCancelledPublication)

  describe "the close protocol" $ do
    it "closes the middle of three windows, leaving the others observing and executing"
      (boundedExample testCloseMiddle)
    it "closes windows in the order A, B, C through their own ports, disposing each with its callbacks detached first"
      (boundedExample (testCloseOrder [0, 1, 2]))
    it "closes windows in the order C, A, B through their own ports, disposing each with its callbacks detached first"
      (boundedExample (testCloseOrder [2, 0, 1]))
    it "answers a retained port, borrow, and close of a disposed window with typed terminal results and no native call"
      (boundedExample testStaleHandles)
    it "settles a closing window's queued callers as not executed, after the commands its port admitted first"
      (boundedExample testQueuedCallersSettled)
    it "defers retirement while a window is borrowed, publishing its closing phase first and its disposal before its snapshot closes"
      (boundedExample testRetirementDeferredByBorrow)
    it "latches a failed release as disposal failed, never retries it, poisons creation, and keeps it as evidence at final exit"
      (boundedExample testReleaseFailurePoisons)
    it "keeps the body's failure primary with a latched release failure retained beside it"
      (boundedExample testOriginalFailurePreserved)

  describe "churn and shutdown" $ do
    it "keeps bookkeeping bounded across repeated creation and honoured close requests, never reissuing an identity"
      (boundedExample testBoundedChurn)
    it "closes every port before the drain and disposes closing and live windows once each after it, settling racing closes as not executed"
      (boundedExample testShutdownWhileClosing)

  describe "fair dispatch" $
    it "serves a waiting window port and the host port within the documented turn bound beside a replenished port, under one budget, through rejections, closure, and creation"
      (boundedExample testFairDispatch)

-- ---------------------------------------------------------------------------
-- Creation

testCreationHandoff ∷ Expectation
testCreationHandoff = do
  seam ← newSeam defaultScript
  requested ← newIORef Nothing
  probes ← newIORef Nothing
  ((settledAs, handedEarly, handedAgain, listed, initial), (initialWindow, created), (own, other, forbidden)) ←
    hosted seam (settings [windowNamed "initial"]) (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          ticket ← submit (hostCommandPort host) (createWindowCommand (windowNamed "created"))
          early ← atomically (pollWindowClient ticket)
          writeIORef requested (Just (ticket, isJust early))
          pure Continue
        2 → do
          (ticket, early) ← slot requested
          settledAs ← disposition ticket
          client ← atomically (pollWindowClient ticket) >>= maybe (unexpected "no capabilities were handed over") pure
          again ← atomically (pollWindowClient ticket)
          listed ← identities host
          initial ← latest (clientObservations client)
          initialWindow ← case listed of
            first : _ → pure first
            [] → unexpected "the host lists no window"
          let port = clientCommandPort client
          tickets ←
            (,,)
              <$> submit port (observeWindowCommand (clientWindow client))
              <*> submit port (observeWindowCommand initialWindow)
              <*> submit port (createWindowCommand (windowNamed "forbidden"))
          writeIORef probes (Just (tickets, (settledAs, early, clientWindow <$> again, listed, initial), (initialWindow, clientWindow client)))
          pure Continue
        _ → do
          ((own, other, forbidden), first, identified) ← slot probes
          settled ← (,,) <$> disposition own <*> disposition other <*> disposition forbidden
          pure (Finish (first, identified, settled))
  settledAs `shouldBe` Just (Performed (WindowCreated created))
  handedEarly `shouldBe` False
  handedAgain `shouldBe` Just created
  listed `shouldBe` [initialWindow, created]
  (observedWindow initial, observedRevision initial, observedPhase initial) `shouldBe` (created, 0, WindowOpen)
  own `shouldSatisfy` \case
    Just (Performed (ObservationPublished published _)) → published == created
    _ → False
  other `shouldBe` Just (Rejected (WindowNotServed initialWindow))
  forbidden `shouldBe` Just (Rejected CreationNotPermitted)
  creations seam `shouldReturn` 2

testCapacityRejection ∷ Expectation
testCapacityRejection = do
  let base = (settings [windowNamed "only"]) {hostWindowLimit = 1}
  validateHostConfig base `shouldBe` Right ()
  validateHostConfig base {hostWindowLimit = 0} `shouldBe` Left (WindowLimitRejected 0)
  validateHostConfig base {hostWindowConfigs = [windowNamed "one", windowNamed "two"]} `shouldBe` Left (WindowLimitRejected 1)
  seam ← newSeam defaultScript
  requested ← newIORef Nothing
  (full, invalid, made, kept) ←
    hosted seam base (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          tickets ←
            (,)
              <$> submit (hostCommandPort host) (createWindowCommand (windowNamed "beyond"))
              <*> submit (hostCommandPort host) (createWindowCommand (windowNamed "bad\NUL"))
          writeIORef requested (Just tickets)
          pure Continue
        _ → do
          (beyond, bad) ← slot requested
          full ← disposition beyond
          invalid ← disposition bad
          made ← creations seam
          kept ← hostBookkeeping host
          pure (Finish (full, invalid, made, kept))
  full `shouldBe` Just (Rejected (WindowCapacityReached 1))
  invalid `shouldBe` Just (Rejected (WindowConfigInvalid WindowTitleRejected))
  made `shouldBe` 1
  (bookkeepingWindows kept, bookkeepingMembers kept) `shouldBe` (1, 1)

testFailedCreationRollback ∷ Expectation
testFailedCreationRollback = do
  (reporting, arm) ← armedOnce
  seam ← newSeam defaultScript {scriptAttachWindowCallbacks = \reporter → reporting >>= \now → when now (reportError reporter 0x00010008 "attach reported")}
  requested ← newIORef Nothing
  retried ← newIORef Nothing
  (failedAs, kept, listed, live, gone, recovered) ←
    hosted seam (settings []) {hostWindowLimit = 1} (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          arm
          submit (hostCommandPort host) (createWindowCommand (windowNamed "failing")) >>= writeIORef requested . Just
          pure Continue
        2 → do
          failedAs ← slot requested >>= disposition
          kept ← hostBookkeeping host
          listed ← identities host
          live ← seamLiveWindowCallbacks seam
          gone ← destroyed seam
          ticket ← submit (hostCommandPort host) (createWindowCommand (windowNamed "after"))
          writeIORef retried (Just (ticket, (failedAs, kept, listed, live, gone)))
          pure Continue
        _ → do
          (ticket, (failedAs, kept, listed, live, gone)) ← slot retried
          recovered ← disposition ticket
          pure (Finish (failedAs, kept, listed, live, gone, recovered))
  failedAs `shouldSatisfy` \case
    Just (Rejected (WindowCreationFailed (Just "attach window callbacks") NativeCallReturned reports)) →
      reports == Reports [NativeError 0x00010008 "attach reported" False ProcessMainThread] 0 0
    _ → False
  (bookkeepingWindows kept, bookkeepingMembers kept, listed, live, gone) `shouldBe` (0, 0, [], 0, [1])
  -- The limit is one, so the failure consumed no capacity.
  recovered `shouldSatisfy` \case
    Just (Performed (WindowCreated window)) → windowLocalIdentity window == 2
    _ → False

testRollbackCleanupPoisons ∷ Expectation
testRollbackCleanupPoisons = do
  (reporting, armReport) ← armedOnce
  (raising, armRaise) ← armedOnce
  seam ←
    newSeam
      defaultScript
        { scriptAttachWindowCallbacks = \reporter → reporting >>= \now → when now (reportError reporter 0x00010008 "attach reported")
        , scriptDestroyWindow = \_ → raising >>= \now → when now (throwIO (userError "release raised"))
        }
  observed ← newIORef Nothing
  requested ← newIORef Nothing
  (failure, caught) ←
    caughtHosted seam (settings []) (\host _ → pure host) $ \host control →
        looping host control $ \turn → case turnNumber turn of
          1 → do
            armReport >> armRaise
            submit (hostCommandPort host) (createWindowCommand (windowNamed "failing")) >>= writeIORef requested . Just
            pure Continue
          2 → do
            first ← slot requested >>= disposition
            ticket ← submit (hostCommandPort host) (createWindowCommand (windowNamed "refused"))
            writeIORef requested (Just ticket)
            writeIORef observed (Just (first, Nothing))
            pure Continue
          _ → do
            (first, _) ← slot observed
            second ← slot requested >>= disposition
            writeIORef observed (Just (first, second))
            pure (Finish ())
  displayException (failure ∷ IOException) `shouldBe` "user error (release raised)"
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw window"]
  (first, second) ← slot observed
  first `shouldSatisfy` \case
    Just (Rejected (WindowCreationFailed {})) → True
    _ → False
  second `shouldBe` Just (Rejected WindowCreationPoisoned)

testDroppedCreationTicket ∷ Expectation
testDroppedCreationTicket = do
  seam ← newSeam defaultScript
  held ← newIORef Nothing
  journal ← newTVarIO []
  (listed, phase) ←
    hosted
      seam
      (settings [])
      (\host control → startSupervised control (required Service) (drainWatcher held journal) >>= expectStarted >> pure host)
      ( \host control →
          looping host control $ \turn → case turnNumber turn of
            1 → do
              void (submitWindowCommand (hostCommandPort host) [] (createWindowCommand (windowNamed "unawaited")))
              pure Continue
            _ →
              identities host >>= \case
                [] → pure Continue
                listed → do
                  observations ← forM listed (fmap clientObservations . clientOf host)
                  writeIORef held (Just observations)
                  phases ← mapM (fmap observedPhase . latest) observations
                  pure (Finish (length listed, phases))
      )
  (listed, phase) `shouldBe` (1, [WindowOpen])
  readTVarIO journal `shouldReturn` [[WindowOpen]]
  slot held >>= mapM (fmap observedPhase . latest) >>= (`shouldBe` [WindowReleased])
  destroyed seam `shouldReturn` [1]

testCancelledConstruction ∷ Expectation
testCancelledConstruction = do
  owner ← newIORef Nothing
  (killing, arm) ← armedOnce
  -- The new window's initial sample asks another thread to cancel the owner,
  -- then yields until that cancellation is delivered. Construction runs with the
  -- owner's own masking state, so it is delivered inside the sample; had
  -- construction been masked, the cancelling thread would block instead, which
  -- fails the example.
  seam ←
    newSeam
      defaultScript
        { scriptWindowSize = \_ → do
            now ← killing
            when now $ do
              target ← slot owner
              killer ← forkIO (killThread target)
              awaitDelivery killer
            pure (800, 600)
        }
  requested ← newIORef Nothing
  enumerated ← newIORef Nothing
  (cancelled, _) ←
    caughtAs $
      hosted seam (settings [windowNamed "kept"]) (\host _ → pure host) $ \host control → do
        myThreadId >>= writeIORef owner . Just
        outcome ←
          try . looping host control $ \turn → case turnNumber turn of
            1 → do
              arm
              submit (hostCommandPort host) (createWindowCommand (windowNamed "cancelled")) >>= writeIORef requested . Just
              pure Continue
            _ → pure (Continue ∷ TurnStep ())
        case outcome of
          Right () → unexpected "the loop finished"
          Left (caught ∷ SomeException) → do
            listed ← identities host
            kept ← hostBookkeeping host
            writeIORef enumerated (Just (length listed, bookkeepingMembers kept))
            throwIO caught
  cancelled `shouldBe` ThreadKilled
  ticket ← slot requested
  disposition ticket >>= (`shouldSatisfy` interrupted)
  atomically (pollWindowClient ticket) >>= (`shouldSatisfy` isNothing)
  (listed, members) ← slot enumerated
  -- Rolled back before the loop saw the cancellation: no registry entry, and its
  -- capacity reclaimed.
  (listed, members) `shouldBe` (1, 1)
  destroyed seam `shouldReturn` [2, 1]
  seamLiveWindowCallbacks seam `shouldReturn` 0

testCancelledPublication ∷ Expectation
testCancelledPublication = do
  owner ← newIORef Nothing
  (killing, arm) ← armedOnce
  -- The host's private hook runs at the end of the new window's registration,
  -- masked. It asks another thread to cancel the owner and returns once that
  -- cancellation is pending, so it lands after both registrations and before the
  -- creation's result is published.
  let hooks =
        noHostHooks
          { afterRegistration = do
              now ← killing
              when now $ do
                target ← slot owner
                killer ← forkIO (killThread target)
                awaitThrowPending killer
          }
  seam ← newSeam defaultScript
  requested ← newIORef Nothing
  enumerated ← newIORef Nothing
  (cancelled, _) ←
    caughtAs $
      hostedWith hooks seam (settings [windowNamed "kept"]) (\host _ → pure host) $ \host control → do
        myThreadId >>= writeIORef owner . Just
        outcome ←
          try . looping host control $ \turn → case turnNumber turn of
            1 → do
              arm
              submit (hostCommandPort host) (createWindowCommand (windowNamed "published")) >>= writeIORef requested . Just
              pure Continue
            _ → pure (Continue ∷ TurnStep ())
        case outcome of
          Right () → unexpected "the loop finished"
          Left (caught ∷ SomeException) → do
            listed ← identities host
            observations ← forM listed (fmap clientObservations . clientOf host)
            writeIORef enumerated (Just (length listed, observations))
            throwIO caught
  cancelled `shouldBe` ThreadKilled
  ticket ← slot requested
  disposition ticket >>= (`shouldSatisfy` interrupted)
  atomically (pollWindowClient ticket) >>= (`shouldSatisfy` isNothing)
  (count, observations) ← slot enumerated
  count `shouldBe` 2
  mapM (fmap observedPhase . latest) observations `shouldReturn` [WindowReleased, WindowReleased]
  destroyed seam `shouldReturn` [2, 1]

-- ---------------------------------------------------------------------------
-- The close protocol

testCloseMiddle ∷ Expectation
testCloseMiddle = do
  seam ← newSeam defaultScript
  stage ← newIORef Nothing
  (closed, listed, middlePhase, gone, observed) ←
    hosted seam (settings (map windowNamed ["a", "b", "c"])) (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          windows ← clients host
          middle ← at windows 1
          ticket ← submit (hostCommandPort host) (closeWindowCommand (clientWindow middle))
          writeIORef stage (Just (windows, ticket, [], (Nothing, [], WindowOpen, [])))
          pure Continue
        2 → do
          (windows, ticket, _, _) ← slot stage
          closed ← disposition ticket
          listed ← identities host
          middlePhase ← at windows 1 >>= phaseOf
          gone ← destroyed seam
          others ← forM [0, 2] $ \index → do
            client ← at windows index
            submit (clientCommandPort client) (observeWindowCommand (clientWindow client))
          writeIORef stage (Just (windows, ticket, others, (closed, listed, middlePhase, gone)))
          pure Continue
        _ → do
          (windows, _, others, (closed, listed, middlePhase, gone)) ← slot stage
          observed ← mapM disposition others
          outer ← mapM (fmap clientWindow . at windows) [0, 2]
          pure (Finish (closed, listed == outer, middlePhase, gone, zip outer observed))
  closed `shouldSatisfy` \case
    Just (Performed (WindowCloseBegun _)) → True
    _ → False
  listed `shouldBe` True
  middlePhase `shouldBe` WindowReleased
  gone `shouldBe` [2]
  forM_ observed $ \(window, settled) →
    settled `shouldSatisfy` \case
      Just (Performed (ObservationPublished published _)) → published == window
      _ → False
  -- The remaining windows are disposed at the host's exit, newest first.
  destroyed seam `shouldReturn` [2, 3, 1]

testCloseOrder ∷ [Int] → Expectation
testCloseOrder order = do
  seam ← newSeam defaultScript
  held ← newIORef []
  closes ← newIORef []
  (settled, listed, phases, ended) ←
    hosted seam (settings (map windowNamed ["a", "b", "c"])) (\host _ → pure host) $ \host control →
      looping host control $ \turn → do
        let number = fromIntegral (turnNumber turn) ∷ Int
        when (number == 1) (clients host >>= writeIORef held)
        windows ← readIORef held
        if number <= length order
          then do
            client ← at windows (order !! (number - 1))
            ticket ← submit (clientCommandPort client) (closeWindowCommand (clientWindow client))
            modifyIORef' closes (<> [ticket])
            pure Continue
          else do
            settled ← readIORef closes >>= mapM disposition
            listed ← identities host
            phases ← mapM phaseOf windows
            ended ← forM windows $ \client → do
              let reader = clientObservations client
              observation ← atomically (readSnapshot reader)
              remaining reader (observedCursor observation)
            pure (Finish (settled, listed, phases, ended))
  windows ← readIORef held
  expected ← forM order (fmap clientWindow . at windows)
  settled `shouldBe` map (Just . Performed . WindowCloseBegun) expected
  listed `shouldBe` []
  phases `shouldBe` replicate 3 WindowReleased
  ended `shouldBe` replicate 3 []
  destroyed seam `shouldReturn` map (+ 1) order
  calls ← seamCalls seam
  forM_ order $ \index →
    (elemIndex (DetachWindowCallbacks (index + 1)) calls < elemIndex (DestroyWindow (index + 1)) calls)
      `shouldBe` True

testStaleHandles ∷ Expectation
testStaleHandles = do
  seam ← newSeam defaultScript
  stage ← newIORef Nothing
  ((started, viaPort, waited, borrowed, again, withdrawn, nativeCalls), stale, (viaHost, phase, ended)) ←
    hosted seam (settings (map windowNamed ["stale", "kept"])) (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          client ← clients host >>= (`at` 0)
          let window = clientWindow client
          started ← closeHostWindow host window
          before ← length <$> seamCalls seam
          viaPort ← submitWindowCommand (clientCommandPort client) [] (observeWindowCommand window)
          waited ← awaitSubmitWindowCommand (clientCommandPort client) [] (closeWindowCommand window)
          borrowed ← withHostWindow host window (\_ → pure ())
          again ← closeHostWindow host window
          withdrawn ← isNothing <$> atomically (hostWindowClient host window)
          after ← length <$> seamCalls seam
          ticket ← submit (hostCommandPort host) (observeWindowCommand window)
          writeIORef stage (Just (client, ticket, (started, viaPort, waited, borrowed, again, withdrawn, after - before)))
          pure Continue
        _ → do
          (client, ticket, probed) ← slot stage
          viaHost ← disposition ticket
          let reader = clientObservations client
          observation ← atomically (readSnapshot reader)
          ended ← remaining reader (observedCursor observation)
          pure (Finish (probed, clientWindow client, (viaHost, observedPhase (preparedValue (observedValue observation)), ended)))
  started `shouldBe` CloseStarted
  viaPort `shouldBe` SubmitClosed
  waited `shouldBe` WaitClosed
  borrowed `shouldBe` WindowEnded stale
  again `shouldBe` CloseNotServed
  withdrawn `shouldBe` True
  nativeCalls `shouldBe` 0
  viaHost `shouldBe` Just (Rejected (WindowNotServed stale))
  phase `shouldBe` WindowReleased
  ended `shouldBe` []

testQueuedCallersSettled ∷ Expectation
testQueuedCallersSettled = do
  seam ← newSeam defaultScript
  stage ← newIORef Nothing
  (started, direct, own, repeated) ←
    hosted seam (settings (map windowNamed ["direct", "commanded"])) {hostCommandCapacity = 4} (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          windows ← clients host
          directClient ← at windows 0
          commanded ← at windows 1
          -- Closed directly while two observations wait in its port.
          queued ← replicateM 2 (submit (clientCommandPort directClient) (observeWindowCommand (clientWindow directClient)))
          started ← closeHostWindow host (clientWindow directClient)
          direct ← mapM disposition queued
          -- Its own port admits an observation, its close, and two more.
          let target = clientWindow commanded
          own ←
            mapM
              (submit (clientCommandPort commanded))
              [observeWindowCommand target, closeWindowCommand target, observeWindowCommand target, observeWindowCommand target]
          writeIORef stage (Just (target, own, Nothing, (started, direct)))
          pure Continue
        2 → do
          (target, own, _, probed) ← slot stage
          again ← submit (hostCommandPort host) (closeWindowCommand target)
          writeIORef stage (Just (target, own, Just again, probed))
          pure Continue
        _ → do
          (_, own, again, (started, direct)) ← slot stage
          settled ← mapM disposition own
          repeated ← maybe (pure Nothing) disposition again
          pure (Finish (started, direct, settled, repeated))
  started `shouldBe` CloseStarted
  direct `shouldBe` [Just NotExecuted, Just NotExecuted]
  map kind own `shouldBe` ["performed", "close begun", "not executed", "not executed"]
  repeated `shouldSatisfy` \case
    Just (Rejected (WindowNotServed _)) → True
    _ → False

testRetirementDeferredByBorrow ∷ Expectation
testRetirementDeferredByBorrow = do
  seam ← newSeam defaultScript
  stage ← newIORef Nothing
  ((started, repeated, closingPhase, kept), deferredOther, (listedAfterBorrows, goneAfterBorrows), (listed, gone, slow, prompt)) ←
    hosted seam (settings (map windowNamed ["kept", "borrowed", "other"])) (\host _ → pure host) $ \host control →
      looping host control $ \turn → case turnNumber turn of
        1 → do
          windows ← clients host
          kept ← at windows 0
          borrowed ← at windows 1
          other ← at windows 2
          let reader = clientObservations borrowed
          opened ← observedCursor <$> atomically (readSnapshot reader)
          inside ←
            withHostWindow host (clientWindow borrowed) $ \_ → do
              started ← closeHostWindow host (clientWindow borrowed)
              repeated ← closeHostWindow host (clientWindow borrowed)
              closing ← atomically (readSnapshot reader)
              bookkeeping ← hostBookkeeping host
              pure (started, repeated, closing, bookkeeping)
          (started, repeated, closing, bookkeeping) ← case inside of
            WindowAvailable probed → pure probed
            WindowEnded _ → unexpected "the borrowed window had ended"
          deferredOther ← withHostWindow host (clientWindow kept) (\_ → closeHostWindow host (clientWindow other))
          afterBorrows ← (,) <$> identities host <*> destroyed seam
          let probed =
                ( (started, repeated, observedPhase (preparedValue (observedValue closing)), bookkeeping)
                , deferredOther
                , afterBorrows
                )
          writeIORef stage (Just (map clientWindow windows, reader, opened, observedCursor closing, probed))
          pure Continue
        _ → do
          (windows, reader, opened, closing, (inside, deferredOther, (listedAfter, goneAfter))) ← slot stage
          listed ← identities host
          gone ← destroyed seam
          slow ← remaining reader opened
          prompt ← remaining reader closing
          keptWindow ← at windows 0
          pure (Finish (inside, deferredOther, (listedAfter == windows, goneAfter), (listed == [keptWindow], gone, slow, prompt)))
  (started, repeated, closingPhase) `shouldBe` (CloseStarted, CloseAlreadyStarted, WindowClosing)
  (bookkeepingWindows kept, bookkeepingClosing kept, bookkeepingBorrowed kept) `shouldBe` (3, 1, 1)
  deferredOther `shouldBe` WindowAvailable CloseStarted
  (listedAfterBorrows, goneAfterBorrows) `shouldBe` (True, [])
  (listed, gone) `shouldBe` (True, [2, 3])
  -- A reader that saw the window open skips its closing phase and still
  -- receives the disposal before the end of the stream.
  slow `shouldBe` [WindowReleased]
  prompt `shouldBe` [WindowReleased]
  detachments seam `shouldReturn` [2, 3, 1]

testReleaseFailurePoisons ∷ Expectation
testReleaseFailurePoisons = do
  (reporting, arm) ← armedOnce
  seam ← newSeam defaultScript {scriptDetachWindowCallbacks = \reporter → reporting >>= \now → when now (reportError reporter 0x00010008 "detach reported")}
  stage ← newIORef Nothing
  observed ← newIORef Nothing
  (failure, caught) ←
    caughtHosted seam (settings (map windowNamed ["kept", "failing"])) (\host _ → pure host) $ \host control →
        looping host control $ \turn → case turnNumber turn of
          1 → do
            windows ← clients host
            kept ← at windows 0
            failing ← at windows 1
            arm
            started ← closeHostWindow host (clientWindow failing)
            listed ← identities host
            phase ← phaseOf failing
            creation ← submit (hostCommandPort host) (createWindowCommand (windowNamed "refused"))
            observation ← submit (clientCommandPort kept) (observeWindowCommand (clientWindow kept))
            writeIORef stage (Just (creation, observation, (started, listed == [clientWindow kept], phase)))
            pure Continue
          _ → do
            (creation, observation, probed) ← slot stage
            settled ← (,) <$> disposition creation <*> disposition observation
            writeIORef observed (Just (probed, settled))
            pure (Finish ())
  failure `shouldBe` NativeFailure NativeCallReturned (Reports [NativeError 0x00010008 "detach reported" False ProcessMainThread] 0 0)
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw window callbacks"]
  ((started, onlyKept, phase), (creation, observation)) ← slot observed
  (started, onlyKept, phase) `shouldBe` (CloseStarted, True, WindowDisposalFailed)
  creation `shouldBe` Just (Rejected WindowCreationPoisoned)
  kind observation `shouldBe` "performed"
  -- The failed release ran once and was not attempted again at the exit.
  detachments seam `shouldReturn` [2, 1]
  destroyed seam `shouldReturn` [2, 1]

testOriginalFailurePreserved ∷ Expectation
testOriginalFailurePreserved = do
  (reporting, arm) ← armedOnce
  seam ← newSeam defaultScript {scriptDetachWindowCallbacks = \reporter → reporting >>= \now → when now (reportError reporter 0x00010008 "detach reported")}
  (failure, caught) ←
    caughtHosted seam (settings (map windowNamed ["kept", "failing"])) (\host _ → pure host) $ \host control →
        looping host control $ \_ → do
          failing ← clients host >>= (`at` 1)
          arm
          _ ← closeHostWindow host (clientWindow failing)
          throwIO (Broken "action failed") ∷ IO (TurnStep ())
  failure `shouldBe` Broken "action failed"
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw window callbacks"]
  destroyed seam `shouldReturn` [2, 1]

-- ---------------------------------------------------------------------------
-- Churn and shutdown

-- | Where one creation and close cycle is.
data Cycle
  = Creating !Int
  | Awaiting !Int !CompletionTicket
  | Requesting !Int !WindowClient
  | Retiring !Int !WindowClient

testBoundedChurn ∷ Expectation
testBoundedChurn = do
  seam ← newSeam defaultScript
  created ← newIORef []
  samples ← newIORef []
  cycleState ← newIORef (Creating 0)
  final ←
    hosted seam (settings []) {hostWindowLimit = 1} (\host _ → pure host) $ \host control →
      looping host control $ \turn → do
        hostBookkeeping host >>= \sample → modifyIORef' samples (sample :)
        readIORef cycleState >>= \case
          Creating done
            | done == cycles → Finish <$> hostBookkeeping host
            | otherwise → do
                ticket ← submit (hostCommandPort host) (createWindowCommand (windowNamed "churned"))
                writeIORef cycleState (Awaiting done ticket)
                pure Continue
          Awaiting done ticket →
            atomically (pollWindowClient ticket) >>= \case
              Nothing → do
                settled ← disposition ticket
                when (isJust settled) (unexpected ("the creation settled without capabilities: " <> show settled))
                pure Continue
              Just client → do
                modifyIORef' created (<> [clientWindow client])
                queued ← withHostWindow host (clientWindow client) (\window → seamQueueEvents seam window [CloseRequested])
                unless (queued == WindowAvailable ()) (unexpected "the created window could not be borrowed")
                writeIORef cycleState (Requesting done client)
                pure Continue
          Requesting done client → case turnCloseRequests turn of
            [] → pure Continue
            [request] | closeRequestWindow request == clientWindow client → do
              honoured ← honourHostCloseRequest host request
              unless (honoured == CloseStarted) (unexpected ("the close request was answered " <> show honoured))
              writeIORef cycleState (Retiring done client)
              pure Continue
            requests → unexpected ("unexpected close requests " <> show requests)
          Retiring done client →
            identities host >>= \case
              [] → do
                phase ← phaseOf client
                unless (phase == WindowReleased) (unexpected ("a churned window ended " <> show phase))
                writeIORef cycleState (Creating (done + 1))
                pure Continue
              _ → pure Continue
  windows ← readIORef created
  length windows `shouldBe` cycles
  let locals = map windowLocalIdentity windows
  and (zipWith (<) locals (drop 1 locals)) `shouldBe` True
  observed ← readIORef samples
  maximum (map bookkeepingWindows observed) `shouldBe` 1
  maximum (map bookkeepingMembers observed) `shouldBe` 1
  maximum (map bookkeepingPorts observed) `shouldBe` 2
  maximum (map bookkeepingSurfaced observed) `shouldBe` 1
  maximum (map bookkeepingPendingCells observed) `shouldSatisfy` (<= 1)
  maximum (map bookkeepingBorrowed observed) `shouldBe` 0
  final `shouldBe` HostBookkeeping 0 0 0 1 0 0 0
  where
    cycles = 40

testShutdownWhileClosing ∷ Expectation
testShutdownWhileClosing = do
  seam ← newSeam defaultScript
  journal ← newTVarIO []
  held ← newIORef []
  (deferred, racing) ←
    hosted
      seam
      (settings (map windowNamed ["a", "b", "c"]))
      ( \host control → do
          windows ← clients host
          writeIORef held windows
          _ ← startSupervised control (required Service) (drainProbe windows journal) >>= expectStarted
          pure host
      )
      ( \host control →
          looping host control $ \_ → do
            windows ← readIORef held
            middle ← at windows 1
            newest ← at windows 2
            -- Closing begins inside a borrow, so the run ends with it unretired.
            deferred ← withHostWindow host (clientWindow middle) (\_ → closeHostWindow host (clientWindow middle))
            racing ← replicateM 2 (submit (hostCommandPort host) (closeWindowCommand (clientWindow newest)))
            pure (Finish (deferred, racing))
      )
  deferred `shouldBe` WindowAvailable CloseStarted
  mapM disposition racing `shouldReturn` [Just NotExecuted, Just NotExecuted]
  readTVarIO journal
    `shouldReturn` [(SubmitClosed, WindowOpen), (SubmitClosed, WindowClosing), (SubmitClosed, WindowOpen)]
  readIORef held >>= mapM phaseOf >>= (`shouldBe` replicate 3 WindowReleased)
  detachments seam `shouldReturn` [3, 2, 1]
  destroyed seam `shouldReturn` [3, 2, 1]

-- ---------------------------------------------------------------------------
-- Fair dispatch

-- | A busy window's port is refilled to capacity on every turn with commands
-- that alternate between its own window and another, which its port rejects.
-- Beside it, a quiet window's port waits on two commands and the host's port on
-- one, then the quiet window closes and a new window is created and commanded
-- through its own port. With at most four ports and a budget of two, the
-- documented bound for a command at position @k@ of its port is @⌈4k / 2⌉@
-- turns: every tracked command submitted during a turn's update, at the position
-- it is tracked with or earlier, has settled by the update that many turns
-- later.
testFairDispatch ∷ Expectation
testFairDispatch = do
  seam ← newSeam defaultScript
  busyTickets ← newIORef []
  alternation ← newIORef (0 ∷ Int)
  tracked ← newIORef ([] ∷ [(Text, Natural, Natural, CompletionTicket)])
  problems ← newIORef ([] ∷ [Text])
  budgets ← newIORef []
  held ← newIORef Nothing
  (settled, busySettled) ←
    hosted
      seam
      (settings (map windowNamed ["busy", "quiet"])) {hostWindowLimit = 3, hostCommandCapacity = 4, hostCommandBudget = 2}
      (\host _ → pure host)
      ( \host control →
          looping host control $ \turn → do
            let number = turnNumber turn
            modifyIORef' budgets (<> [turnCommands turn])
            when (number == 1) $ do
              windows ← clients host
              (,) <$> at windows 0 <*> at windows 1 >>= writeIORef held . Just
            (busy, quiet) ← slot held
            readIORef tracked >>= mapM_ (\(label, submitted, position, ticket) → do
              pending ← isNothing <$> disposition ticket
              when (pending && number >= submitted + bound position) (modifyIORef' problems (<> [label <> " waited past its bound"])))
            busyOrder ← readIORef busyTickets >>= mapM (fmap isJust . disposition)
            unless (and (zipWith (>=) busyOrder (drop 1 busyOrder))) (modifyIORef' problems (<> ["the busy port settled out of order"]))
            let track label position port command = do
                  ticket ← submit port command
                  modifyIORef' tracked (<> [(label, number, position, ticket)])
                  pure ticket
            case number of
              1 → do
                void (track "quiet" 1 (clientCommandPort quiet) (observeWindowCommand (clientWindow quiet)))
                void (track "quiet second" 2 (clientCommandPort quiet) (observeWindowCommand (clientWindow quiet)))
                void (track "host" 1 (hostCommandPort host) (observeWindowCommand (clientWindow busy)))
              3 → do
                -- At most second in its port, behind the quiet window's second command.
                void (track "close" 2 (clientCommandPort quiet) (closeWindowCommand (clientWindow quiet)))
                void (track "create" 1 (hostCommandPort host) (createWindowCommand (windowNamed "created")))
              5 → do
                creation ← readIORef tracked >>= \entries → case [ticket | ("create", _, _, ticket) ← entries] of
                  ticket : _ → pure ticket
                  [] → unexpected "no creation was tracked"
                client ← atomically (pollWindowClient creation) >>= maybe (unexpected "the creation handed nothing over") pure
                void (track "created" 1 (clientCommandPort client) (observeWindowCommand (clientWindow client)))
              7 → void (track "host again" 1 (hostCommandPort host) (observeWindowCommand (clientWindow busy)))
              _ → pure ()
            refill busyTickets alternation busy quiet
            if number < 12
              then pure Continue
              else do
                outcomes ← readIORef tracked >>= mapM (\(label, _, _, ticket) → (label,) . kind <$> disposition ticket)
                busyOutcomes ← readIORef busyTickets >>= mapM (fmap kind . disposition)
                pure (Finish (outcomes, busyOutcomes))
      )
  readIORef problems `shouldReturn` []
  spent ← readIORef budgets
  all (<= 2) spent `shouldBe` True
  drop 1 spent `shouldBe` replicate (length spent - 1) 2
  settled
    `shouldBe` [ ("quiet", "performed")
               , ("quiet second", "performed")
               , ("host", "performed")
               , ("close", "close begun")
               , ("create", "created")
               , ("created", "performed")
               , ("host again", "performed")
               ]
  "rejected" `elem` busySettled `shouldBe` True
  "performed" `elem` busySettled `shouldBe` True
  where
    -- ⌈k · P / B⌉ with at most P = 1 + hostWindowLimit = 4 ports and a budget B = 2.
    bound ∷ Natural → Natural
    bound position = (position * 4 + 1) `div` 2

-- | Fill the busy window's port to capacity, alternating between a command for
-- its own window and one for the quiet window.
refill ∷ IORef [CompletionTicket] → IORef Int → WindowClient → WindowClient → IO ()
refill tickets alternation busy quiet = do
  index ← readIORef alternation
  let target = if even index then clientWindow busy else clientWindow quiet
  submitWindowCommand (clientCommandPort busy) [("client", "busy")] (observeWindowCommand target) >>= \case
    SubmitAccepted ticket → do
      modifyIORef' tickets (<> [ticket])
      writeIORef alternation (index + 1)
      refill tickets alternation busy quiet
    _ → pure ()

-- ---------------------------------------------------------------------------
-- Applications, workers, and helpers

-- | A logging lifetime whose records go nowhere.
lifetime ∷ (LoggingLifetime → IO r) → IO r
lifetime = withLoggingLifetime (mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ())))

-- | Run an application over a host in the seam's session, on a bound thread
-- designated as the process main thread.
hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hosted seam config startup action =
  asProcessMainThread seam $
    runWindowApplication lifetime "dynamic-example" (allocWindowHostIn (seamSession seam defaultSessionConfig) config) id startup action

-- | 'hosted' with the host's private hooks.
hostedWith ∷ HostHooks → Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hostedWith hooks seam config startup action =
  asProcessMainThread seam $
    runWindowApplication lifetime "dynamic-example" (allocWindowHostWith hooks (seamSession seam defaultSessionConfig) config) id startup action

-- | 'hosted', expecting the run to fail, and catching the failure on the bound
-- thread itself: 'runInBoundThread' rethrows a failure without the context its
-- cleanup evidence is read from.
caughtHosted ∷ Exception e ⇒ Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO (e, SomeException)
caughtHosted seam config startup action =
  asProcessMainThread seam . caughtAs $
    runWindowApplication lifetime "dynamic-example" (allocWindowHostIn (seamSession seam defaultSessionConfig) config) id startup action

-- | Run the owner loop with no application events, handing each turn to the
-- update, and fail an example that has not finished within 'turnBound' turns.
looping ∷ WindowHost → RuntimeControl → (Turn → IO (TurnStep a)) → IO a
looping host control update =
  runOwnerLoop host control . LoopHooks noApplicationEvents $ \turn →
    if turnNumber turn > turnBound
      then unexpected "the example did not finish within its turn bound"
      else update turn

turnBound ∷ Natural
turnBound = 400

settings ∷ [WindowConfig] → HostConfig
settings windows =
  (defaultHostConfig windows)
    { hostWindowLimit = 3
    , hostCommandCapacity = 4
    , hostCommandBudget = 4
    , hostEventBudget = 1
    , hostIdleWait = 0.01
    }

windowNamed ∷ Text → WindowConfig
windowNamed name = hiddenTestWindowConfig name 64 48

submit ∷ WindowCommandPort → WindowCommand → IO CompletionTicket
submit port command =
  submitWindowCommand port [] command >>= \case
    SubmitAccepted ticket → pure ticket
    other → unexpected ("the submission was not admitted: " <> show other)

disposition ∷ CompletionTicket → IO (Maybe Disposition)
disposition = atomically . pollCompletion

identities ∷ WindowHost → IO [WindowId]
identities = atomically . hostWindowIdentities

clientOf ∷ WindowHost → WindowId → IO WindowClient
clientOf host target = atomically (hostWindowClient host target) >>= maybe (unexpected "the host holds no such window") pure

clients ∷ WindowHost → IO [WindowClient]
clients host = identities host >>= mapM (clientOf host)

at ∷ [a] → Int → IO a
at values index = case drop index values of
  value : _ → pure value
  [] → unexpected ("no element at " <> show index)

latest ∷ SnapshotReader WindowObservation → IO WindowObservation
latest reader = preparedValue . observedValue <$> atomically (readSnapshot reader)

phaseOf ∷ WindowClient → IO WindowPhase
phaseOf = fmap observedPhase . latest . clientObservations

-- | Every later publication's phase from a cursor, until the stream ends.
remaining ∷ SnapshotReader WindowObservation → SnapshotCursor WindowObservation → IO [WindowPhase]
remaining reader cursor =
  atomically (awaitSnapshot reader cursor) >>= \case
    Updated observation →
      (observedPhase (preparedValue (observedValue observation)) :) <$> remaining reader (observedCursor observation)
    EndOfStream → pure []

slot ∷ IORef (Maybe a) → IO a
slot ref = readIORef ref >>= maybe (unexpected "nothing was stored by an earlier step") pure

-- | A switch a scripted native step reads and turns off, and the action that
-- turns it on.
armedOnce ∷ IO (IO Bool, IO ())
armedOnce = do
  switch ← newIORef False
  pure (atomicModifyIORef' switch (False,), writeIORef switch True)

creations ∷ Seam → IO Int
creations seam = (\calls → length [() | CreateWindow {} ← calls]) <$> seamCalls seam

destroyed ∷ Seam → IO [Int]
destroyed seam = (\calls → [key | DestroyWindow key ← calls]) <$> seamCalls seam

detachments ∷ Seam → IO [Int]
detachments seam = (\calls → [key | DetachWindowCallbacks key ← calls]) <$> seamCalls seam

-- | Yield until a cancelling thread's exception is delivered to the calling
-- thread, which must be unmasked; a caller that is masked instead fails.
awaitDelivery ∷ ThreadId → IO ()
awaitDelivery thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → throwIO (userError "the cancellation was held back: the caller was masked")
    _ → yield >> awaitDelivery thread

-- | Wait until a thread is blocked delivering an exception to a masked thread.
awaitThrowPending ∷ ThreadId → IO ()
awaitThrowPending thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → throwIO (userError "the cancellation was delivered while the owner was unmasked")
    ThreadDied → throwIO (userError "the cancelling thread died")
    _ → yield >> awaitThrowPending thread

kind ∷ Maybe Disposition → String
kind = \case
  Nothing → "pending"
  Just (Performed (ObservationPublished {})) → "performed"
  Just (Performed (WindowCreated {})) → "created"
  Just (Performed (WindowCloseBegun {})) → "close begun"
  Just (Rejected _) → "rejected"
  Just NotExecuted → "not executed"
  Just (Interrupted _) → "interrupted"
  Just (Unsupported _) → "unsupported"
  Just (Attempted _) → "attempted"
  Just (Transitioned _) → "transitioned"

interrupted ∷ Maybe Disposition → Bool
interrupted = \case
  Just (Interrupted _) → True
  _ → False

newtype Broken = Broken Text
  deriving (Eq, Show)

instance Exception Broken

testComponent ∷ Component
testComponent = unsafeComponent "test.dynamic"

required ∷ Role → WorkerPolicy
required role = WorkerPolicy role Supervision.Required testComponent (\_ → pure Unrecognized)

expectStarted ∷ SupervisedStart r → IO ()
expectStarted = \case
  WorkerStarted _ → pure ()
  WorkerStartUnavailable _ _ → unexpected "the worker was unavailable"
  WorkerStartRejected → unexpected "the worker's start was rejected"

-- | A service that runs until stopped and records, at its release, the phases
-- of the windows the owner stored for it.
drainWatcher ∷ IORef (Maybe [SnapshotReader WindowObservation]) → TVar [[WindowPhase]] → WorkerDefinition ()
drainWatcher held journal =
  workerDefinition
    "drain watcher"
    ( \_ →
        allocResource (pure ()) $ \() →
          readIORef held >>= mapM_ (\readers → do
            phases ← mapM (fmap observedPhase . latest) readers
            atomically (modifyTVar' journal (<> [phases])))
    )
    (\token () → atomically (awaitStopRequest token))

-- | A service that runs until stopped and records, at its release, what each
-- window's own port answers and the phase each window is in.
drainProbe ∷ [WindowClient] → TVar [(SubmitResult, WindowPhase)] → WorkerDefinition ()
drainProbe windows journal =
  workerDefinition
    "drain probe"
    ( \_ →
        allocResource (pure ()) $ \() →
          forM_ windows $ \client → do
            answer ← submitWindowCommand (clientCommandPort client) [] (observeWindowCommand (clientWindow client))
            phase ← phaseOf client
            atomically (modifyTVar' journal (<> [(answer, phase)]))
    )
    (\token () → atomically (awaitStopRequest token))
