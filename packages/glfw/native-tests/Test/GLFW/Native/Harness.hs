-- | The fixture's own settlement rules.
--
-- The scripted-owner examples run 'runOwned' on the example's thread over a
-- resource that records its acquisition and release, so ordering, counts, and
-- failures are observable without GLFW: lazy single acquisition, nothing
-- acquired by a dry run or an empty selection, a deliberately failing nested
-- example, a cancelled borrower with work in flight and queued, an owner that
-- fails while a borrower waits, an owner cancelled again while it settles the
-- first cancellation — with a clean release and with a failing one — an owner
-- cancelled once more while its release still runs, an owner with a
-- cancellation already pending at its acquisition's handoff to the borrower,
-- cancelled again during the release, an owner cancelled while its
-- acquisition is blocked, and an acquisition failure. The shared-session
-- examples repeat the failing and cancelled cases
-- against the real session on the process main thread. Every deliberate
-- failure is inside a nested run or a forked borrower and is asserted as
-- expected, so this suite still passes.
--
-- Coordination is explicit throughout: gates, the fixture's queue count, and
-- thread outcomes. Nothing waits on time.
module Test.GLFW.Native.Harness (spec) where

import Control.Concurrent
  ( ThreadId
  , forkFinally
  , killThread
  , myThreadId
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  , throwTo
  , yield
  )
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception (..)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , displayException
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (replicateM, unless, void, when)
import Data.Foldable (for_)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), threadStatus)
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Failure
  ( FailureCause (EngineOrigin)
  , FailureOrigin (originOperation)
  , failureCause
  , failureEvidence
  , operation
  , operationText
  , throwFailure
  )
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Resource (allocResource, cleanupFailureException, cleanupFailures, withResource)
import Hetoimasia.GLFW.Session (sessionBackend)
import System.Exit (ExitCode (ExitSuccess))
import Test.GLFW.Native.Fixture
  ( Owner (..)
  , OwnerReport (..)
  , awaitQueued
  , dispatch
  , ownerThread
  , queuedCount
  , runOwned
  )
import Test.GLFW.Native.Support (Shared (..), acquisitions, consented, failed, owned, sharedBackend)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe, shouldReturn)
import Test.Hspec.Core.Formatters.V2 (formatterToFormat, silent)
import Test.Hspec.Runner
  ( Config (configDryRun, configFailOnEmpty, configFilterPredicate, configFormat)
  , SpecResult
  , defaultConfig
  , evalSpec
  , resultItemIsFailure
  , runSpecForest
  , specResultItems
  , specResultSuccess
  )

spec ∷ Shared → Spec
spec shared = describe "the shared fixture" $ do
  describe "with a scripted owner" $ do
    it "acquires lazily and once for every borrowed operation, and releases after the borrower settles" $ do
      script ← newScript False False
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          values ← replicateM 3 (dispatch fixture pure)
          note script "borrower finished"
          pure values
      either throwIO pure outcome `shouldReturn` [7, 7, 7]
      reportAcquisitions report `shouldBe` 1
      reportServed report `shouldBe` 3
      noOwnerFailure report
      events script `shouldReturn` ["acquired", "borrower finished", "owner settled", "released"]

    it "rethrows a dispatched operation's failure with its failure evidence and retained cleanup failures" $ do
      script ← newScript False False
      (outcome, report) ←
        runOwned (scripted script) $ \fixture →
          try . dispatch fixture $ \_ →
            withResource
              (pure ())
              (\() → throwIO ReleaseFailed)
              (\() → throwFailure (unsafeComponent "fixture") (operation "scripted operation") [] AcquisitionFailed)
      caught ← either throwIO pure outcome >>= either pure (\() → failed "the operation returned")
      fromException caught `shouldBe` Just AcquisitionFailed
      case failureCause (failureEvidence caught) of
        EngineOrigin origin → operationText (originOperation origin) `shouldBe` "scripted operation"
        _ → failed "the failure lost its engine origin crossing the dispatcher"
      let retained = [inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures caught)]
      map fromException retained `shouldBe` [Just ReleaseFailed]
      noOwnerFailure report

    it "acquires nothing when no operation is dispatched" $ do
      script ← newScript False False
      (outcome, report) ← runOwned (scripted script) (\_ → pure ())
      either throwIO pure outcome
      reportAcquisitions report `shouldBe` 0
      noOwnerFailure report
      events script `shouldReturn` []

    it "acquires nothing for a dry run, and fails an empty selection without acquiring" $ do
      script ← newScript False False
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          let dispatching = it "dispatches an operation" (void (dispatch fixture pure))
          dry ← runNested (\config → config {configDryRun = True}) dispatching
          -- Hspec ends an empty selection under --fail-on=empty by exiting
          -- rather than by returning a failed result, so the refusal is the
          -- exit, caught here as the expected outcome.
          empty ←
            try $
              runNested
                (\config → config {configFailOnEmpty = True, configFilterPredicate = Just (const False)})
                dispatching
          pure
            ( specResultSuccess dry
            , length (specResultItems dry)
            , either (\(code ∷ ExitCode) → code /= ExitSuccess) (not . specResultSuccess) empty
            )
      either throwIO pure outcome `shouldReturn` (True, 1, True)
      reportAcquisitions report `shouldBe` 0
      events script `shouldReturn` []

    it "settles a deliberately failing example that used the resource, and keeps serving" $ do
      script ← newScript False False
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          nested ←
            runNested id . it "fails after its operation" $
              dispatch fixture pure `shouldReturn` 8
          after ← dispatch fixture pure
          pure (failures nested, after)
      either throwIO pure outcome `shouldReturn` (1, 7)
      reportAcquisitions report `shouldBe` 1
      noOwnerFailure report

    it "settles a cancelled borrower's in-flight and queued operations, running only the in-flight one" $ do
      script ← newScript False False
      gate ← newEmptyMVar
      started ← newEmptyMVar
      ranQueued ← newIORef False
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          (inFlight, inFlightOutcome) ←
            forked . dispatch fixture $ \value → do
              putMVar started ()
              takeMVar gate
              note script "in-flight operation finished"
              pure value
          takeMVar started
          (queued, queuedOutcome) ← forked . dispatch fixture $ \value → writeIORef ranQueued True >> pure value
          awaitQueued fixture 2
          killThread queued
          killThread inFlight
          cancelledQueued ← queuedOutcome
          cancelledInFlight ← inFlightOutcome
          putMVar gate ()
          after ← dispatch fixture pure
          note script "borrower finished"
          pure (killed cancelledQueued, killed cancelledInFlight, after)
      either throwIO pure outcome `shouldReturn` (True, True, 7)
      readIORef ranQueued `shouldReturn` False
      reportServed report `shouldBe` 2
      reportDeclined report `shouldBe` 1
      noOwnerFailure report
      events script
        `shouldReturn` ["acquired", "in-flight operation finished", "borrower finished", "owner settled", "released"]

    it "wakes a borrower waiting on an owner that fails with that failure, and releases after it settles, keeping cleanup evidence" $ do
      script ← newScript False True
      gate ← newEmptyMVar ∷ IO (MVar ())
      started ← newEmptyMVar
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          (_, waited) ← forked . dispatch fixture $ \_ → putMVar started () >> takeMVar gate
          takeMVar started
          throwTo (ownerThread fixture) OwnerKilled
          woken ← waited
          note script "borrower finished"
          refused ← try (dispatch fixture pure)
          pure (woken, refused)
      (woken, refused) ← either throwIO pure outcome
      failedWith OwnerKilled woken `shouldBe` True
      failedWith OwnerKilled refused `shouldBe` True
      events script `shouldReturn` ["acquired", "borrower finished", "released"]
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just OwnerKilled
      let retained = [inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures failure)]
      map fromException retained `shouldBe` [Just ReleaseFailed]

    it "keeps the resource alive through repeated owner cancellation during settlement, the first cancellation primary" $ do
      script ← newScript False False
      started ← newEmptyMVar
      never ← newEmptyMVar ∷ IO (MVar ())
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          (_, waited) ← forked . dispatch fixture $ \value → putMVar started () >> takeMVar never >> pure value
          takeMVar started
          throwTo (ownerThread fixture) OwnerKilled
          woken ← waited
          -- The owner is settling the first cancellation, waiting for this
          -- borrower. A second cancellation is delivered to that wait — the
          -- throwTo returns — while the borrower has not finished.
          (_, cancelledAgain) ← forked (throwTo (ownerThread fixture) OwnerKilledAgain)
          delivered ← cancelledAgain
          note script "borrower finished"
          pure (woken, delivered)
      (woken, delivered) ← either throwIO pure outcome
      failedWith OwnerKilled woken `shouldBe` True
      either throwIO pure delivered
      events script `shouldReturn` ["acquired", "borrower finished", "released"]
      reportAcquisitions report `shouldBe` 1
      reportServed report `shouldBe` 0
      reportDeclined report `shouldBe` 0
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just OwnerKilled

    it "keeps the release's cleanup evidence beside the first cancellation through repeated cancellation during settlement" $ do
      script ← newScript False True
      started ← newEmptyMVar
      never ← newEmptyMVar ∷ IO (MVar ())
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          (_, waited) ← forked . dispatch fixture $ \value → putMVar started () >> takeMVar never >> pure value
          takeMVar started
          throwTo (ownerThread fixture) OwnerKilled
          woken ← waited
          (_, cancelledAgain) ← forked (throwTo (ownerThread fixture) OwnerKilledAgain)
          delivered ← cancelledAgain
          note script "borrower finished"
          pure (woken, delivered)
      (woken, delivered) ← either throwIO pure outcome
      failedWith OwnerKilled woken `shouldBe` True
      either throwIO pure delivered
      events script `shouldReturn` ["acquired", "borrower finished", "released"]
      reportAcquisitions report `shouldBe` 1
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just OwnerKilled
      let retained = [inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures failure)]
      map fromException retained `shouldBe` [Just ReleaseFailed]

    it "keeps the initiating failure primary when a later cancellation is deferred through the release" $ do
      (script, enteredRelease, releaseGate) ← newScriptBlockingRelease True
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          served ← dispatch fixture pure
          throwTo (ownerThread fixture) OwnerKilled
          -- Once the release begins, a further cancellation is aimed at the
          -- owner; the release is uninterruptible, so it is delivered only
          -- after the release finishes. The gate is opened only once the
          -- cancellation is observed pending, so the deferral is certain.
          (canceller, cancelled) ← forked $ do
            readMVar enteredRelease
            throwTo (ownerThread fixture) OwnerKilledAgain
          (_, opened) ← forked $ do
            readMVar enteredRelease
            awaitThrowing canceller
            putMVar releaseGate ()
          note script "borrower finished"
          pure (served, cancelled, opened)
      (served, cancelled, opened) ← either throwIO pure outcome
      served `shouldBe` 7
      cancelled >>= either throwIO pure
      opened >>= either throwIO pure
      events script `shouldReturn` ["acquired", "borrower finished", "released"]
      reportAcquisitions report `shouldBe` 1
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just OwnerKilled
      let retained = [inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures failure)]
      map fromException retained `shouldBe` [Just ReleaseFailed]

    it "settles a cancellation pending at the acquisition handoff, and a later one deferred through the release" $ do
      (script, enteredRelease, releaseGate) ← newScriptBlockingRelease True
      owner ← myThreadId
      throwerWait ← newEmptyMVar ∷ IO (MVar (IO (Either SomeException ())))
      let -- The acquisition pends a cancellation on the owner and returns with
          -- it pending, so the delivery lands exactly at the handoff to the
          -- borrower.
          acquire = do
            (thrower, thrown) ← forked (throwTo owner OwnerKilled)
            uninterruptibleMask_ (awaitThrowing thrower)
            putMVar throwerWait thrown
            note script "acquired"
            pure (7 ∷ Int)
          release _ = do
            putMVar enteredRelease ()
            takeMVar releaseGate
            note script "released"
            throwIO ReleaseFailed
          pendingOwner = Owner (allocResource acquire release) (note script "owner settled")
      (outcome, report) ←
        runOwned pendingOwner $ \fixture → do
          woken ← try (dispatch fixture pure)
          (canceller, cancelled) ← forked $ do
            readMVar enteredRelease
            throwTo (ownerThread fixture) OwnerKilledAgain
          (_, opened) ← forked $ do
            readMVar enteredRelease
            awaitThrowing canceller
            putMVar releaseGate ()
          note script "borrower finished"
          pure (woken, cancelled, opened)
      (woken, cancelled, opened) ← either throwIO pure outcome
      failedWith OwnerKilled woken `shouldBe` True
      cancelled >>= either throwIO pure
      opened >>= either throwIO pure
      thrown ← takeMVar throwerWait
      thrown >>= either throwIO pure
      events script `shouldReturn` ["acquired", "borrower finished", "released"]
      reportAcquisitions report `shouldBe` 1
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just OwnerKilled
      let retained = [inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures failure)]
      map fromException retained `shouldBe` [Just ReleaseFailed]

    it "interrupts a blocked acquisition with a cancellation, answering the waiter with it" $ do
      (script, enteredAcquire, _acquireGate) ← newScriptBlockingAcquire
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          (_, waited) ← forked (dispatch fixture pure)
          readMVar enteredAcquire
          -- Delivered while the owner blocks in the acquisition: the throwTo
          -- returning proves the delivery, so the acquisition stayed
          -- interruptible.
          throwTo (ownerThread fixture) OwnerKilled
          woken ← waited
          note script "borrower finished"
          pure woken
      woken ← either throwIO pure outcome
      failedWith OwnerKilled woken `shouldBe` True
      events script `shouldReturn` ["borrower finished"]
      reportAcquisitions report `shouldBe` 1
      reportServed report `shouldBe` 0
      reportDeclined report `shouldBe` 1
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just OwnerKilled

    it "answers every borrower with an acquisition failure, never retries it, and releases nothing" $ do
      script ← newScript True False
      (outcome, report) ←
        runOwned (scripted script) $ \fixture → do
          first ← try (dispatch fixture pure)
          second ← try (dispatch fixture pure)
          pure (first, second)
      (first, second) ← either throwIO pure outcome
      failedWith AcquisitionFailed first `shouldBe` True
      failedWith AcquisitionFailed second `shouldBe` True
      reportAcquisitions report `shouldBe` 1
      reportServed report `shouldBe` 0
      reportDeclined report `shouldBe` 2
      events script `shouldReturn` ["acquired"]
      failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
      fromException failure `shouldBe` Just AcquisitionFailed

  consented (sharedGate shared) . describe "with the shared session" $ do
    it "settles a deliberately failing example that used the session, and keeps serving" $ do
      nested ←
        runNested id . it "fails after a native operation" $
          owned shared (pure . sessionBackend) >>= (`shouldNotBe` sharedBackend (sharedGate shared))
      failures nested `shouldBe` 1
      owned shared (pure . sessionBackend) `shouldReturn` sharedBackend (sharedGate shared)
      acquisitions shared `shouldReturn` 1

    it "settles a cancelled example's in-flight and queued operations on the owner, and keeps serving" $ do
      gate ← newEmptyMVar
      started ← newEmptyMVar
      ranQueued ← newIORef False
      finishedInFlight ← newIORef False
      (inFlight, inFlightOutcome) ←
        forked . owned shared $ \session → do
          putMVar started ()
          takeMVar gate
          writeIORef finishedInFlight True
          pure (sessionBackend session)
      takeMVar started
      before ← queuedCount (sharedFixture shared)
      (queued, queuedOutcome) ← forked . owned shared $ \session → writeIORef ranQueued True >> pure (sessionBackend session)
      awaitQueued (sharedFixture shared) (before + 1)
      killThread queued
      killThread inFlight
      queuedOutcome >>= (`shouldBe` True) . killed
      inFlightOutcome >>= (`shouldBe` True) . killed
      putMVar gate ()
      owned shared (pure . sessionBackend) `shouldReturn` sharedBackend (sharedGate shared)
      readIORef finishedInFlight `shouldReturn` True
      readIORef ranQueued `shouldReturn` False
      acquisitions shared `shouldReturn` 1

-- ---------------------------------------------------------------------------
-- A scripted owner

data Script = Script
  { scriptLog ∷ TVar [String]
  , scriptAcquireFails ∷ Bool
  , scriptReleaseFails ∷ Bool
  , scriptAcquireWait ∷ Maybe (MVar (), MVar ())
    -- ^ When set, the acquisition announces it has begun on the first 'MVar'
    -- and then blocks on the second, so an example can cancel the owner while
    -- the acquisition is blocked.
  , scriptReleaseWait ∷ Maybe (MVar (), MVar ())
    -- ^ When set, the release announces it has begun on the first 'MVar' and
    -- then blocks on the second, so an example can aim a cancellation at the
    -- owner while the uninterruptible release runs.
  }

data ScriptedFailure = AcquisitionFailed | ReleaseFailed
  deriving (Eq, Show)

instance Exception ScriptedFailure

-- | An owner stopped from outside while it serves.
data OwnerKilled = OwnerKilled
  deriving (Eq, Show)

instance Exception OwnerKilled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | A second cancellation aimed at an owner already settling 'OwnerKilled',
-- distinguishable from it in the report.
data OwnerKilledAgain = OwnerKilledAgain
  deriving (Eq, Show)

instance Exception OwnerKilledAgain where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

newScript ∷ Bool → Bool → IO Script
newScript acquireFails releaseFails = do
  entries ← newTVarIO []
  pure (Script entries acquireFails releaseFails Nothing Nothing)

-- | A script whose acquisition announces it has begun and then blocks on a
-- gate, so an example can cancel the owner while the acquisition is blocked.
newScriptBlockingAcquire ∷ IO (Script, MVar (), MVar ())
newScriptBlockingAcquire = do
  entries ← newTVarIO []
  entered ← newEmptyMVar
  gate ← newEmptyMVar
  pure (Script entries False False (Just (entered, gate)) Nothing, entered, gate)

-- | A script whose release announces it has begun and then blocks on a gate,
-- so an example can aim a cancellation at the owner while the release runs.
newScriptBlockingRelease ∷ Bool → IO (Script, MVar (), MVar ())
newScriptBlockingRelease releaseFails = do
  entries ← newTVarIO []
  entered ← newEmptyMVar
  gate ← newEmptyMVar
  pure (Script entries False releaseFails Nothing (Just (entered, gate)), entered, gate)

note ∷ Script → String → IO ()
note script entry = atomically (modifyTVar' (scriptLog script) (<> [entry]))

events ∷ Script → IO [String]
events = readTVarIO . scriptLog

scripted ∷ Script → Owner Int
scripted script =
  Owner
    { ownerAcquire = allocResource acquire release
    , ownerSettled = note script "owner settled"
    }
  where
    acquire = do
      for_ (scriptAcquireWait script) $ \(entered, gate) → putMVar entered () >> takeMVar gate
      note script "acquired"
      when (scriptAcquireFails script) (throwIO AcquisitionFailed)
      pure 7
    release _ = do
      for_ (scriptReleaseWait script) $ \(entered, gate) → putMVar entered () >> takeMVar gate
      note script "released"
      when (scriptReleaseFails script) (throwIO ReleaseFailed)

-- ---------------------------------------------------------------------------
-- Helpers

-- | Start an action on a thread of its own; the second value waits for its
-- outcome, which is recorded even when the thread is killed before it runs.
forked ∷ IO a → IO (ThreadId, IO (Either SomeException a))
forked action = do
  finished ← newEmptyMVar
  thread ← forkFinally action (putMVar finished)
  pure (thread, readMVar finished)

-- | Wait until the thread is blocked delivering an exception, so a
-- cancellation aimed at an uninterruptible owner is known to be pending before
-- the blocker it waits on is released.
awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thread = do
  status ← threadStatus thread
  unless (status == ThreadBlocked BlockedOnException) (yield >> awaitThrowing thread)

-- | Run a nested spec silently, independent of this run's own options.
runNested ∷ (Config → Config) → Spec → IO SpecResult
runNested adjust nested = do
  (config, forest) ← evalSpec defaultConfig nested
  runSpecForest forest (adjust config) {configFormat = Just (formatterToFormat silent)}

failures ∷ SpecResult → Int
failures = length . filter resultItemIsFailure . specResultItems

killed ∷ Either SomeException a → Bool
killed = either ((== Just ThreadKilled) . fromException) (const False)

failedWith ∷ (Exception e, Eq e) ⇒ e → Either SomeException a → Bool
failedWith expected = either ((== Just expected) . fromException) (const False)

noOwnerFailure ∷ OwnerReport → IO ()
noOwnerFailure report =
  maybe (pure ()) (\failure → failed ("the owner failed: " <> displayException failure)) (reportFailure report)
