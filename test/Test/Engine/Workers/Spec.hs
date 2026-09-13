-- | Examples for 'Hetoimasia.Foundation.Worker'.
--
-- Every example runs injected CPU actions on real worker threads inside real
-- CPU scopes and observes what a caller can see: the 'StartOutcome', each
-- 'Completion', the 'GroupReport', the failure that propagated with its worker
-- and cleanup evidence, and an ordered trace of acquisitions, releases, and
-- worker effects. No example constructs a logger or a production worker.
--
-- Coordination is explicit: 'MVar's, STM, and 'threadStatus' decide when a
-- thread has reached the point an example needs. No sleep is a concurrency
-- assertion and no example asserts a wall-clock bound; 'boundedExample' only
-- stops an example that has already hung. The stuck-worker and blocked-delivery
-- examples release their worker explicitly before checking disposal, and no
-- example expects arbitrary blocking IO to be interrupted.
module Test.Engine.Workers.Spec (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, throwTo, yield)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , takeMVar
  , tryPutMVar
  , tryReadMVar
  )
import Control.Concurrent.STM
  ( atomically
  , check
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled, UserInterrupt)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throwIO
  , try
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM, forM_, replicateM_, unless, void)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (elemIndex)
import Data.Maybe (isNothing)
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (failureCause)
  , FailureOrigin (..)
  , failureEvidenceInContext
  , operation
  , throwFailure
  )
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Resource
  ( Scoped
  , acquirePart
  , allocComposite
  , allocResource
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , releaseRank
  , withScoped
  )
import Hetoimasia.Foundation.Worker
  ( Completion (..)
  , GroupReport (..)
  , Requested (..)
  , Result (..)
  , RunEnd (..)
  , RunExit (..)
  , StartOutcome (..)
  , StartRejection (..)
  , Startup (..)
  , Worker
  , WorkerCancelled (..)
  , WorkerEvidence (..)
  , activeWorkerCount
  , allocWorkerGroup
  , awaitCompletion
  , awaitStartup
  , awaitStopRequest
  , closeWorkerGroup
  , observeCompletion
  , pollCompletion
  , requestCancel
  , requestStop
  , startWorker
  , startWorkerWith
  , withWorkerGroup
  , workerDefinition
  , workerEvidenceInContext
  , workerId
  )
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldSatisfy
  )

spec ∷ Spec
spec = describe "Workers" $ do
  describe "Startup" $ do
    it "acknowledges startup after initialization and keeps the worker's resources live for its run"
      (boundedExample testAcknowledgedStartup)
    it "reports a typed startup failure retaining its origin and cleanup evidence"
      (boundedExample testStartupFailure)
    it "publishes cancellation during startup as run-not-entered without inventing a run exit"
      (boundedExample testCancelledDuringStartup)
    it "drains a child whose starter is cancelled before the starter's dependencies are released"
      (boundedExample testCancelledStartupWait)
    it "prepares before any child code and drains the child when a composed wait fails"
      (boundedExample testComposedWaitFailure)
    it "cancels and drains the fork it owns when preparation fails"
      (boundedExample testPreparationFailure)
    it "reports acknowledgement and completion ready together"
      (boundedExample testAcknowledgedAndCompleted)

  describe "Requests and observation" $ do
    it "keeps a repeated stop request idempotent and records it at exit"
      (boundedExample testIdempotentStop)
    it "delivers repeated cancellation requests through one owned helper"
      (boundedExample testIdempotentCancel)
    it "lets an observer be cancelled without cancelling or joining the worker"
      (boundedExample testCancellableObservation)
    it "reports a worker's cancellation to an observer without cancelling the observer"
      (boundedExample testObservedCancellation)
    it "publishes completion after cleanup, identically to several readers"
      (boundedExample testMultipleReaders)

  describe "Closing and drain" $ do
    it "requests every stop before waiting for any worker"
      (boundedExample testAllStopsBeforeJoin)
    it "rejects a start after closing without forking"
      (boundedExample testRejectedAfterClosing)
    it "synchronizes registration with closing"
      (boundedExample testRegistrationClosingRace)
    it "keeps a run exit before the stop request recorded when the request lands during cleanup"
      (boundedExample testExitBeforeStopDuringCleanup)
    it "snapshots an outcome published before closing as exited rather than stopped"
      (boundedExample testExitedBeforeClosing)
    it "cancels live workers on owner failure and propagates that failure after their cleanup"
      (boundedExample testOwnerFailure)
    it "keeps draining through a further cancellation of the owner"
      (boundedExample testFurtherCancellationDuringDrain)
    it "keeps the parent alive for a worker that ignores its stop request until it is released"
      (boundedExample testStuckWorker)
    it "keeps the parent alive while a cancellation delivery blocks, until the worker is released"
      (boundedExample testBlockedCancellationDelivery)

  describe "Retirement" $ do
    it "retires observed workers while retained handles keep their results"
      (boundedExample testRetirement)
    it "keeps an observed failure through retirement and an exceptional group exit"
      (boundedExample testObservedFailureAtExit)

-- Fixtures -------------------------------------------------------------------

data Broken = Broken Text
  deriving (Eq, Show)

instance Exception Broken

data Kind
  = SucceededKind
  | FailedKind
  | CancelledKind
  deriving (Eq, Show)

kindOf ∷ Completion r → Kind
kindOf completion = case completionResult completion of
  Succeeded _ → SucceededKind
  Failed _ → FailedKind
  Cancelled _ → CancelledKind

failureOf ∷ Completion r → IO (ExceptionWithContext SomeException)
failureOf completion = case completionResult completion of
  Succeeded _ → fail "expected a failed or cancelled completion, but it succeeded"
  Failed caught → pure caught
  Cancelled caught → pure caught

isException ∷ (Exception e, Eq e) ⇒ e → ExceptionWithContext SomeException → Bool
isException expected (ExceptionWithContext _ exception) = fromException exception == Just expected

contextOf ∷ ExceptionWithContext SomeException → [WorkerEvidence]
contextOf (ExceptionWithContext context _) = workerEvidenceInContext context

cleanupLabels ∷ ExceptionWithContext SomeException → [Text]
cleanupLabels (ExceptionWithContext context _) = map cleanupFailureLabel (cleanupFailuresInContext context)

expectSucceeded ∷ Completion r → IO r
expectSucceeded completion = case completionResult completion of
  Succeeded value → pure value
  _ → fail ("expected a success, found " <> show (kindOf completion))

expectStarted ∷ StartOutcome r → IO (Worker r)
expectStarted (Started worker) = pure worker
expectStarted (StartupFailed _ completion) =
  fail ("expected acknowledgement, but startup ended " <> show (kindOf completion))
expectStarted (StartRejected rejection) = fail ("expected acknowledgement, found " <> show rejection)

expectFailure ∷ Either (ExceptionWithContext SomeException) a → IO (ExceptionWithContext SomeException)
expectFailure (Left caught) = pure caught
expectFailure (Right _) = fail "expected a failure to propagate, but the owner returned"

newTrace ∷ IO (IORef [Text])
newTrace = newIORef []

record ∷ IORef [Text] → Text → IO ()
record trace entry = atomicModifyIORef' trace (\entries → (entries <> [entry], ()))

-- | A resource whose acquisition and release are traced.
resource ∷ IORef [Text] → Text → Scoped ()
resource trace name =
  allocResource (record trace ("acquire " <> name)) (\() → record trace ("release " <> name))

-- | A labelled resource whose release is traced and then throws.
failingResource ∷ IORef [Text] → Text → Scoped ()
failingResource trace name =
  allocComposite $
    acquirePart name (releaseRank 0)
      (record trace ("acquire " <> name))
      (\() → record trace ("release " <> name) >> throwIO (Broken ("release " <> name)))

-- | Run an owner on its own thread, keeping what escaped it.
forkOwner ∷ IO a → IO (ThreadId, MVar (Either (ExceptionWithContext SomeException) a))
forkOwner action = do
  done ← newEmptyMVar
  thread ← forkIO (tryWithContext action >>= putMVar done)
  pure (thread, done)

-- | Wait until a thread is blocked in an STM transaction.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM thread = do
  status ← threadStatus thread
  case status of
    ThreadBlocked BlockedOnSTM → pure ()
    _ → yield >> awaitBlockedOnSTM thread

-- | Require an absent value whose type has no 'Show' instance.
expectNothing ∷ Maybe a → Expectation
expectNothing Nothing = pure ()
expectNothing (Just _) = expectationFailure "expected nothing yet, but a value was present"

-- | Require an empty list whose elements have no 'Show' instance.
expectEmpty ∷ [a] → Expectation
expectEmpty [] = pure ()
expectEmpty entries = expectationFailure ("expected no entries, found " <> show (length entries))

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- Startup --------------------------------------------------------------------

testAcknowledgedStartup ∷ Expectation
testAcknowledgedStartup = do
  trace ← newTrace
  completion ← withWorkerGroup $ \group → do
    worker ←
      expectStarted
        =<< startWorker group
          ( workerDefinition "acknowledged" (\_ → resource trace "worker buffer") $ \token () → do
              atomically (awaitStopRequest token)
              record trace "stop seen"
              pure (7 ∷ Int)
          )
    record trace "acknowledged"
    atomically (requestStop worker)
    atomically (awaitCompletion worker)
  expectSucceeded completion >>= (`shouldBe` 7)
  completionExit completion `shouldBe` RunExited RunReturned StopWasRequested
  entries ← readIORef trace
  entries `shouldBe` ["acquire worker buffer", "acknowledged", "stop seen", "release worker buffer"]

testStartupFailure ∷ Expectation
testStartupFailure = do
  trace ← newTrace
  (outcome, startup) ← withWorkerGroup $ \group → do
    started ←
      startWorker group $
        workerDefinition
          "failing-startup"
          ( \_ → do
              failingResource trace "worker socket"
              liftIO (throwFailure (unsafeComponent "test.workers") (operation "open-socket") [] (Broken "startup"))
          )
          (\_ () → record trace "run")
    case started of
      StartupFailed worker completion → do
        startup ← atomically (awaitStartup worker)
        pure (completion, startup)
      other → void (expectStarted other) >> fail "expected a startup failure"
  kindOf outcome `shouldBe` FailedKind
  completionExit outcome `shouldBe` RunNotEntered
  case startup of
    NotAcknowledged _ → pure ()
    Acknowledged → expectationFailure "a failed startup must not be acknowledged"
  caught@(ExceptionWithContext context _) ← failureOf outcome
  caught `shouldSatisfy` isException (Broken "startup")
  case failureCause (failureEvidenceInContext context) of
    EngineOrigin origin → originOperation origin `shouldBe` operation "open-socket"
    NativeCause → expectationFailure "the startup failure lost its origin"
  cleanupLabels caught `shouldBe` ["worker socket"]
  map cleanupFailureLabel (completionCleanup outcome) `shouldBe` ["worker socket"]
  readIORef trace >>= (`shouldBe` ["acquire worker socket", "release worker socket"])

testCancelledDuringStartup ∷ Expectation
testCancelledDuringStartup = do
  trace ← newTrace
  handle ← newEmptyMVar
  entered ← newEmptyMVar
  never ← newEmptyMVar
  _ ← forkIO $ do
    worker ← takeMVar handle
    takeMVar entered
    requestCancel worker
  started ← withWorkerGroup $ \group →
    startWorkerWith
      group
      ( workerDefinition
          "cancelled-startup"
          (\_ → resource trace "startup buffer" >> liftIO (putMVar entered () >> takeMVar never))
          (\_ () → record trace "run")
      )
      (putMVar handle)
      awaitStartup
  case started of
    Right (_, NotAcknowledged completion) → do
      kindOf completion `shouldBe` CancelledKind
      completionExit completion `shouldBe` RunNotEntered
      failureOf completion >>= (`shouldSatisfy` isException WorkerCancelled)
    Right (_, Acknowledged) → expectationFailure "a cancelled startup must not be acknowledged"
    Left rejection → expectationFailure (show rejection)
  readIORef trace >>= (`shouldBe` ["acquire startup buffer", "release startup buffer"])
  void (tryPutMVar never ())

testCancelledStartupWait ∷ Expectation
testCancelledStartupWait = do
  trace ← newTrace
  entered ← newEmptyMVar
  never ← newEmptyMVar
  (owner, done) ← forkOwner $
    withScoped (resource trace "parent" >> allocWorkerGroup) $ \group →
      startWorker group $
        workerDefinition
          "slow-startup"
          (\_ → resource trace "child" >> liftIO (putMVar entered () >> takeMVar never))
          (\_ () → record trace "run")
  takeMVar entered
  awaitBlockedOnSTM owner
  killThread owner
  caught ← takeMVar done >>= expectFailure
  caught `shouldSatisfy` isException ThreadKilled
  case contextOf caught of
    [AbandonedStart summary, GroupExit report] → do
      kindOf summary `shouldBe` CancelledKind
      completionExit summary `shouldBe` RunNotEntered
      map completionWorker (reportExitedBeforeClosing report) `shouldBe` [completionWorker summary]
      expectEmpty (reportDrained report)
    _ → expectationFailure "expected the abandoned start and the group exit as evidence"
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child", "release child", "release parent"])
  void (tryPutMVar never ())

testComposedWaitFailure ∷ Expectation
testComposedWaitFailure = do
  trace ← newTrace
  requiredFailed ← newTVarIO False
  entered ← newEmptyMVar
  never ← newEmptyMVar
  _ ← forkIO (takeMVar entered >> atomically (writeTVar requiredFailed True))
  let composed worker =
        awaitStartup worker
          `orElse` (readTVar requiredFailed >>= check >> throwSTM (Broken "required worker failed"))
  outcome ← try $ withWorkerGroup $ \group →
    startWorkerWith
      group
      ( workerDefinition
          "composed-wait"
          ( \_ → do
              liftIO (record trace "child startup")
              resource trace "child"
              liftIO (putMVar entered () >> takeMVar never)
          )
          (\_ () → record trace "run")
      )
      ( \worker → do
          record trace "prepared"
          replicateM_ 100 yield
          acknowledged ← atomically (pollCompletion worker)
          unless (isNothing acknowledged) $ fail "the child ran before preparation finished"
          record trace "prepared done"
      )
      composed
  case outcome of
    Left (Broken reason) → reason `shouldBe` "required worker failed"
    Right _ → expectationFailure "the composed wait's failure must propagate"
  readIORef trace
    >>= (`shouldBe` ["prepared", "prepared done", "child startup", "acquire child", "release child"])
  void (tryPutMVar never ())

testPreparationFailure ∷ Expectation
testPreparationFailure = do
  trace ← newTrace
  outcome ← tryWithContext $ withWorkerGroup $ \group →
    startWorkerWith
      group
      (workerDefinition "unprepared" (\_ → liftIO (record trace "child startup")) (\_ () → record trace "run"))
      (\_ → throwIO (Broken "preparation"))
      awaitStartup
  caught ← expectFailure outcome
  caught `shouldSatisfy` isException (Broken "preparation")
  case contextOf caught of
    AbandonedStart summary : _ → do
      kindOf summary `shouldBe` CancelledKind
      completionExit summary `shouldBe` RunNotEntered
    _ → expectationFailure "expected the abandoned start as evidence"
  readIORef trace >>= (`shouldBe` [])

testAcknowledgedAndCompleted ∷ Expectation
testAcknowledgedAndCompleted =
  withWorkerGroup $ \group → do
    worker ← expectStarted =<< startWorker group (workerDefinition "finite" (\_ → pure ()) (\_ () → pure (5 ∷ Int)))
    _ ← atomically (awaitCompletion worker)
    (startup, completion) ← atomically ((,) <$> awaitStartup worker <*> pollCompletion worker)
    case (startup, completion) of
      (Acknowledged, Just finished) → do
        expectSucceeded finished >>= (`shouldBe` 5)
        completionExit finished `shouldBe` RunExited RunReturned NothingRequested
      _ → expectationFailure "expected acknowledgement and completion to be ready together"

-- Requests and observation ---------------------------------------------------

testIdempotentStop ∷ Expectation
testIdempotentStop =
  withWorkerGroup $ \group → do
    proceed ← newEmptyMVar
    worker ←
      expectStarted
        =<< startWorker group
          (workerDefinition "stoppable" (\_ → pure ()) (\token () → atomically (awaitStopRequest token) >> takeMVar proceed))
    replicateM_ 3 (atomically (requestStop worker))
    putMVar proceed ()
    completion ← atomically (awaitCompletion worker)
    atomically (requestStop worker)
    completionExit completion `shouldBe` RunExited RunReturned StopWasRequested
    after ← atomically (awaitCompletion worker)
    completionExit after `shouldBe` completionExit completion

testIdempotentCancel ∷ Expectation
testIdempotentCancel = do
  deliveries ← newIORef (0 ∷ Int)
  caught ← newEmptyMVar
  finish ← newEmptyMVar
  never ← newEmptyMVar
  report ← withWorkerGroup $ \group → do
    worker ←
      expectStarted
        =<< startWorker group
          ( workerDefinition "cancel-once" (\_ → pure ()) $ \_ () → do
              interrupted ← try (takeMVar never)
              case interrupted of
                Left WorkerCancelled → atomicModifyIORef' deliveries (\n → (n + 1, ())) >> putMVar caught ()
                Right () → pure ()
              takeMVar finish
          )
    replicateM_ 3 (requestCancel worker)
    takeMVar caught
    putMVar finish ()
    completion ← atomically (awaitCompletion worker)
    kindOf completion `shouldBe` SucceededKind
    completionExit completion `shouldBe` RunExited RunReturned CancelWasRequested
    requestCancel worker
    closeWorkerGroup group
  readIORef deliveries >>= (`shouldBe` 1)
  map kindOf (reportExitedBeforeClosing report) `shouldBe` [SucceededKind]
  void (tryPutMVar never ())

testCancellableObservation ∷ Expectation
testCancellableObservation =
  withWorkerGroup $ \group → do
    worker ←
      expectStarted
        =<< startWorker group
          (workerDefinition "observed" (\_ → pure ()) (\token () → atomically (awaitStopRequest token)))
    (observer, observed) ← forkOwner (atomically (awaitCompletion worker))
    awaitBlockedOnSTM observer
    killThread observer
    takeMVar observed >>= expectFailure >>= (`shouldSatisfy` isException ThreadKilled)
    atomically (pollCompletion worker) >>= expectNothing
    atomically (requestStop worker)
    completion ← atomically (awaitCompletion worker)
    completionExit completion `shouldBe` RunExited RunReturned StopWasRequested

testObservedCancellation ∷ Expectation
testObservedCancellation =
  withWorkerGroup $ \group → do
    never ← newEmptyMVar
    worker ←
      expectStarted
        =<< startWorker group (workerDefinition "to-cancel" (\_ → pure ()) (\_ () → takeMVar never))
    (observer, observed) ← forkOwner $ do
      completion ← atomically (awaitCompletion worker)
      pure (kindOf completion, completionExit completion)
    awaitBlockedOnSTM observer
    requestCancel worker
    result ← takeMVar observed
    case result of
      Right (kind, exit) → do
        kind `shouldBe` CancelledKind
        exit `shouldBe` RunExited RunCancelled CancelWasRequested
      Left _ → expectationFailure "observing a cancelled worker must not cancel the observer"
    void (tryPutMVar never ())

testMultipleReaders ∷ Expectation
testMultipleReaders = do
  trace ← newTrace
  releaseGate ← newEmptyMVar
  withWorkerGroup $ \group → do
    let releaseBuffer () = uninterruptibleMask_ (takeMVar releaseGate) >> record trace "release worker buffer"
    worker ←
      expectStarted
        =<< startWorker group
          ( workerDefinition
              "readers"
              (\_ → allocResource (record trace "acquire worker buffer") releaseBuffer)
              (\_ () → pure (42 ∷ Int))
          )
    readers ← forM ["first", "second"] $ \name → forkOwner $ do
      completion ← atomically (awaitCompletion worker)
      record trace ("read by " <> name)
      value ← expectSucceeded completion
      pure (completionWorker completion, completionExit completion, value)
    forM_ readers (awaitBlockedOnSTM . fst)
    atomically (pollCompletion worker) >>= expectNothing
    putMVar releaseGate ()
    results ← forM readers (takeMVar . snd)
    let expected = (workerId worker, RunExited RunReturned NothingRequested, 42)
    forM_ results $ \case
      Right observed → observed `shouldBe` expected
      Left _ → expectationFailure "a reader failed"
  entries ← readIORef trace
  let position entry = maybe (length entries) id (elemIndex entry entries)
  position "release worker buffer" `shouldSatisfy` (< position "read by first")
  position "release worker buffer" `shouldSatisfy` (< position "read by second")

-- Closing and drain ----------------------------------------------------------

testAllStopsBeforeJoin ∷ Expectation
testAllStopsBeforeJoin = do
  seen ← newTVarIO (0 ∷ Int)
  -- Each worker counts its own stop in one transaction and exits only once all
  -- three have counted theirs, which a drain that joined between stop requests
  -- would never allow.
  let definition name = workerDefinition name (\_ → pure ()) $ \token () → do
        atomically (awaitStopRequest token >> modifyTVar' seen (+ 1))
        atomically (readTVar seen >>= check . (== 3))
  report ← withWorkerGroup $ \group → do
    forM_ ["first", "second", "third"] $ \name → void (expectStarted =<< startWorker group (definition name))
    closeWorkerGroup group
  map completionExit (reportDrained report)
    `shouldBe` replicate 3 (RunExited RunReturned StopWasRequested)

testRejectedAfterClosing ∷ Expectation
testRejectedAfterClosing = do
  trace ← newTrace
  outcome ← withWorkerGroup $ \group → do
    _ ← closeWorkerGroup group
    started ← startWorker group (workerDefinition "late" (\_ → liftIO (record trace "forked")) (\_ () → pure ()))
    case started of
      StartRejected rejection → pure rejection
      other → void (expectStarted other) >> fail "expected the start to be rejected"
  outcome `shouldBe` RegistrationClosed
  readIORef trace >>= (`shouldBe` [])

testRegistrationClosingRace ∷ Expectation
testRegistrationClosingRace =
  replicateM_ 200 $ do
    ran ← newIORef False
    (report, started) ← withWorkerGroup $ \group → do
      (_, starting) ← forkOwner $
        startWorker group $
          workerDefinition "racing" (\_ → liftIO (atomicModifyIORef' ran (const (True, ())))) $
            \token () → atomically (awaitStopRequest token)
      report ← closeWorkerGroup group
      started ← takeMVar starting
      pure (report, started)
    everRan ← readIORef ran
    let reported = map completionWorker (reportExitedBeforeClosing report <> reportDrained report)
    case started of
      Right (StartRejected RegistrationClosed) → do
        everRan `shouldBe` False
        reported `shouldBe` []
      Right (Started worker) → reported `shouldBe` [workerId worker]
      Right (StartupFailed worker _) → reported `shouldBe` [workerId worker]
      Left _ → expectationFailure "the racing start failed"

testExitBeforeStopDuringCleanup ∷ Expectation
testExitBeforeStopDuringCleanup = do
  inCleanup ← newEmptyMVar
  proceed ← newEmptyMVar
  report ← withWorkerGroup $ \group → do
    let cleanup () = uninterruptibleMask_ (putMVar inCleanup () >> takeMVar proceed)
    early ←
      expectStarted
        =<< startWorker group (workerDefinition "exits-early" (\_ → allocResource (pure ()) cleanup) (\_ () → pure ()))
    requested ←
      expectStarted
        =<< startWorker group
          (workerDefinition "exits-on-request" (\_ → pure ()) (\token () → atomically (awaitStopRequest token)))
    takeMVar inCleanup
    atomically (pollCompletion early) >>= expectNothing
    (closer, closed) ← forkOwner (closeWorkerGroup group)
    awaitBlockedOnSTM closer
    putMVar proceed ()
    _ ← atomically (awaitCompletion requested)
    takeMVar closed >>= either (const (fail "closing failed")) pure
  map completionExit (reportDrained report)
    `shouldBe` [RunExited RunReturned NothingRequested, RunExited RunReturned StopWasRequested]
  expectEmpty (reportExitedBeforeClosing report)

testExitedBeforeClosing ∷ Expectation
testExitedBeforeClosing = do
  report ← withWorkerGroup $ \group → do
    worker ← expectStarted =<< startWorker group (workerDefinition "already-done" (\_ → pure ()) (\_ () → pure ()))
    _ ← atomically (awaitCompletion worker)
    closeWorkerGroup group
  map completionExit (reportExitedBeforeClosing report) `shouldBe` [RunExited RunReturned NothingRequested]
  expectEmpty (reportDrained report)

testOwnerFailure ∷ Expectation
testOwnerFailure = do
  trace ← newTrace
  never ← newEmptyMVar
  outcome ← tryWithContext $
    withScoped (resource trace "parent" >> allocWorkerGroup) $ \group → do
      _ ←
        expectStarted
          =<< startWorker group
            (workerDefinition "service" (\_ → failingResource trace "child socket") (\_ () → takeMVar never))
      throwIO (Broken "owner")
  caught ← expectFailure outcome
  caught `shouldSatisfy` isException (Broken "owner")
  case contextOf caught of
    [GroupExit report] → do
      -- The cancellation stays primary for the child and its failed release is
      -- retained beside it, exactly as the resource failure table specifies.
      map kindOf (reportDrained report) `shouldBe` [CancelledKind]
      map completionExit (reportDrained report) `shouldBe` [RunExited RunCancelled CancelWasRequested]
      map (map cleanupFailureLabel . completionCleanup) (reportDrained report) `shouldBe` [["child socket"]]
    _ → expectationFailure "expected the group exit as evidence"
  cleanupLabels caught `shouldBe` ["child socket"]
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child socket", "release child socket", "release parent"])
  void (tryPutMVar never ())

testFurtherCancellationDuringDrain ∷ Expectation
testFurtherCancellationDuringDrain = do
  trace ← newTrace
  started ← newEmptyMVar
  cancelSeen ← newEmptyMVar
  release ← newEmptyMVar
  never ← newEmptyMVar
  (owner, done) ← forkOwner $
    withScoped (resource trace "parent" >> allocWorkerGroup) $ \group → do
      _ ←
        expectStarted
          =<< startWorker group
            ( workerDefinition "slow-to-stop" (\_ → resource trace "child") $ \_ () → do
                interrupted ← try (takeMVar never)
                case interrupted of
                  Left WorkerCancelled → putMVar cancelSeen ()
                  Right () → pure ()
                takeMVar release
            )
      putMVar started ()
      takeMVar never
  takeMVar started
  killThread owner
  takeMVar cancelSeen
  awaitBlockedOnSTM owner
  throwTo owner UserInterrupt
  awaitBlockedOnSTM owner
  tryReadMVar done >>= expectNothing
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child"])
  putMVar release ()
  caught ← takeMVar done >>= expectFailure
  caught `shouldSatisfy` isException ThreadKilled
  case contextOf caught of
    [GroupExit report] → map kindOf (reportDrained report) `shouldBe` [SucceededKind]
    _ → expectationFailure "expected the group exit as evidence"
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child", "release child", "release parent"])
  void (tryPutMVar never ())

testStuckWorker ∷ Expectation
testStuckWorker = do
  trace ← newTrace
  bodyDone ← newEmptyMVar
  release ← newEmptyMVar
  (owner, done) ← forkOwner $
    withScoped (resource trace "parent" >> allocWorkerGroup) $ \group → do
      _ ←
        expectStarted
          =<< startWorker group (workerDefinition "ignores-stop" (\_ → resource trace "child") (\_ () → takeMVar release))
      putMVar bodyDone ()
  takeMVar bodyDone
  awaitBlockedOnSTM owner
  tryReadMVar done >>= expectNothing
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child"])
  putMVar release ()
  takeMVar done >>= either (const (expectationFailure "the owner failed")) pure
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child", "release child", "release parent"])

testBlockedCancellationDelivery ∷ Expectation
testBlockedCancellationDelivery = do
  trace ← newTrace
  running ← newEmptyMVar
  failing ← newEmptyMVar
  release ← newEmptyMVar
  (owner, done) ← forkOwner $
    withScoped (resource trace "parent" >> allocWorkerGroup) $ \group → do
      _ ←
        expectStarted
          =<< startWorker group
            ( workerDefinition "uninterruptible" (\_ → resource trace "child") $ \_ () →
                uninterruptibleMask_ (putMVar running () >> takeMVar release)
            )
      takeMVar running
      putMVar failing ()
      throwIO (Broken "owner")
  takeMVar failing
  awaitBlockedOnSTM owner
  tryReadMVar done >>= expectNothing
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child"])
  putMVar release ()
  caught ← takeMVar done >>= expectFailure
  caught `shouldSatisfy` isException (Broken "owner")
  case contextOf caught of
    [GroupExit report] → do
      map kindOf (reportDrained report) `shouldBe` [CancelledKind]
      map completionExit (reportDrained report) `shouldBe` [RunExited RunCancelled CancelWasRequested]
    _ → expectationFailure "expected the group exit as evidence"
  readIORef trace >>= (`shouldBe` ["acquire parent", "acquire child", "release child", "release parent"])

-- Retirement -----------------------------------------------------------------

testRetirement ∷ Expectation
testRetirement =
  withWorkerGroup $ \group → do
    workers ← forM [1 .. 50 ∷ Int] $ \n →
      expectStarted =<< startWorker group (workerDefinition "job" (\_ → pure ()) (\_ () → pure n))
    forM_ workers $ \worker → do
      _ ← atomically (awaitCompletion worker)
      fmap kindOf <$> atomically (observeCompletion worker) >>= (`shouldBe` Just SucceededKind)
    atomically (activeWorkerCount group) >>= (`shouldBe` 0)
    forM_ (zip [1 ..] workers) $ \(n, worker) → do
      completion ← atomically (pollCompletion worker) >>= maybe (fail "a retired handle lost its outcome") pure
      expectSucceeded completion >>= (`shouldBe` n)

testObservedFailureAtExit ∷ Expectation
testObservedFailureAtExit = do
  outcome ← tryWithContext $ withWorkerGroup $ \group → do
    observed ←
      expectStarted
        =<< startWorker group (workerDefinition "observed-failure" (\_ → pure ()) (\_ () → throwIO (Broken "observed")))
    unobserved ←
      expectStarted
        =<< startWorker group (workerDefinition "raw-read-failure" (\_ → pure ()) (\_ () → throwIO (Broken "unobserved")))
    _ ← atomically (awaitCompletion observed)
    _ ← atomically (observeCompletion observed)
    _ ← atomically (awaitCompletion unobserved)
    _ ← atomically (awaitCompletion unobserved)
    atomically (activeWorkerCount group) >>= (`shouldBe` 1)
    throwIO (Broken "owner")
  caught ← expectFailure outcome
  caught `shouldSatisfy` isException (Broken "owner")
  case contextOf caught of
    [GroupExit report] → do
      map completionLabel (reportObservedFailures report) `shouldBe` ["observed-failure"]
      map completionLabel (reportExitedBeforeClosing report) `shouldBe` ["raw-read-failure"]
      expectEmpty (reportDrained report)
      failures ← forM (reportObservedFailures report <> reportExitedBeforeClosing report) failureOf
      map (isException (Broken "observed")) failures `shouldBe` [True, False]
      map (isException (Broken "unobserved")) failures `shouldBe` [False, True]
    _ → expectationFailure "expected the group exit as evidence"
