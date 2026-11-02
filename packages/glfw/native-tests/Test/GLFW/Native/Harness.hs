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
module Test.GLFW.Native.Harness (spec, withForkedIn) where

import Control.Concurrent
  ( ThreadId
  , killThread
  , myThreadId
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  , throwTo
  , yield
  )
import Control.Concurrent.MVar (MVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception (..)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , toException
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
import Test.GLFW.Native.Threads (Boundness (Unbound), Scope, ownedScope, startIn)
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
        runOwned (scripted script) $ \fixture →
          -- The gate holds the owner's in-flight operation, so a scope that ends before the example opens it opens it itself.
          withForkedOpening
            (void (tryPutMVar gate ()))
            ( dispatch fixture $ \value → do
                putMVar started ()
                takeMVar gate
                note script "in-flight operation finished"
                pure value
            )
            $ \inFlight inFlightOutcome → do
              takeMVar started
              withForked (dispatch fixture $ \value → writeIORef ranQueued True >> pure value) $ \queued queuedOutcome → do
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
        runOwned (scripted script) $ \fixture →
          -- The gate holds the owner's operation until the example kills the owner, so a scope that ends first opens it.
          withForkedOpening (void (tryPutMVar gate ())) (dispatch fixture $ \_ → putMVar started () >> takeMVar gate) $ \_ waited → do
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
        runOwned (scripted script) $ \fixture →
          withForkedOpening (void (tryPutMVar never ())) (dispatch fixture $ \value → putMVar started () >> takeMVar never >> pure value) $ \_ waited → do
            takeMVar started
            throwTo (ownerThread fixture) OwnerKilled
            woken ← waited
            -- The owner is settling the first cancellation, waiting for this
            -- borrower. A second cancellation is delivered to that wait — the
            -- throwTo returns — while the borrower has not finished.
            withForked (throwTo (ownerThread fixture) OwnerKilledAgain) $ \_ cancelledAgain → do
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
        runOwned (scripted script) $ \fixture →
          withForkedOpening (void (tryPutMVar never ())) (dispatch fixture $ \value → putMVar started () >> takeMVar never >> pure value) $ \_ waited → do
            takeMVar started
            throwTo (ownerThread fixture) OwnerKilled
            woken ← waited
            withForked (throwTo (ownerThread fixture) OwnerKilledAgain) $ \_ cancelledAgain → do
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
      owner ← myThreadId
      -- Once the release begins, a further cancellation is aimed at the owner;
      -- the release is uninterruptible, so it is delivered only after the
      -- release finishes. The gate is opened only once the cancellation is
      -- observed pending, so the deferral is certain. Both workers act during
      -- the release, after the borrower has returned, so their scopes enclose
      -- the whole run; the release's gate is also opened by the scope that
      -- owns its opener, whatever way that scope ends.
      withForked (readMVar enteredRelease >> throwTo owner OwnerKilledAgain) $ \canceller cancelled →
        withForkedOpening
          (void (tryPutMVar releaseGate ()))
          (readMVar enteredRelease >> awaitThrowing canceller >> putMVar releaseGate ())
          $ \_ opened → do
            (outcome, report) ←
              runOwned (scripted script) $ \fixture → do
                served ← dispatch fixture pure
                throwTo (ownerThread fixture) OwnerKilled
                note script "borrower finished"
                pure served
            served ← either throwIO pure outcome
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
      acquiring ← newEmptyMVar ∷ IO (MVar ())
      let -- The acquisition pends a cancellation on the owner and returns with
          -- it pending, so the delivery lands exactly at the handoff to the
          -- borrower. The thrower waits for the acquisition to begin, which
          -- is while the owner is masked, so its throw stays pending.
          acquire thrower = do
            putMVar acquiring ()
            -- The thrower may run on another capability, where its throw is only a message in this one's inbox until the
            -- scheduler next runs; yielding processes it, so the cancellation is pending before the acquisition returns.
            uninterruptibleMask_ (awaitThrowing thrower >> yield)
            note script "acquired"
            pure (7 ∷ Int)
          release _ = do
            putMVar enteredRelease ()
            takeMVar releaseGate
            note script "released"
            throwIO ReleaseFailed
      -- The thrower, the canceller and the opener all act around the owner's
      -- acquisition and release, so their scopes enclose the whole run.
      withForked (readMVar acquiring >> throwTo owner OwnerKilled) $ \thrower thrown →
        withForked (readMVar enteredRelease >> throwTo owner OwnerKilledAgain) $ \canceller cancelled →
          withForkedOpening
            (void (tryPutMVar releaseGate ()))
            (readMVar enteredRelease >> awaitThrowing canceller >> putMVar releaseGate ())
            $ \_ opened → do
              let pendingOwner = Owner (allocResource (acquire thrower) release) (note script "owner settled")
              (outcome, report) ←
                runOwned pendingOwner $ \fixture → do
                  woken ← try (dispatch fixture pure)
                  note script "borrower finished"
                  pure woken
              woken ← either throwIO pure outcome
              failedWith OwnerKilled woken `shouldBe` True
              cancelled >>= either throwIO pure
              opened >>= either throwIO pure
              thrown >>= either throwIO pure
              events script `shouldReturn` ["acquired", "borrower finished", "released"]
              reportAcquisitions report `shouldBe` 1
              failure ← maybe (failed "the owner reported no failure") pure (reportFailure report)
              fromException failure `shouldBe` Just OwnerKilled
              let retained = [inner | ExceptionWithContext _ inner ← map cleanupFailureException (cleanupFailures failure)]
              map fromException retained `shouldBe` [Just ReleaseFailed]

    it "interrupts a blocked acquisition with a cancellation, answering the waiter with it" $ do
      (script, enteredAcquire, acquireGate) ← newScriptBlockingAcquire
      (outcome, report) ←
        runOwned (scripted script) $ \fixture →
          -- The blocked acquisition is ended by the example's cancellation of the owner; a scope that ends first lets it go.
          withForkedOpening (void (tryPutMVar acquireGate ())) (dispatch fixture pure) $ \_ waited → do
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
      -- The gate holds the owner's in-flight operation, so a scope that ends before the example opens it opens it itself.
      withForkedOpening
        (void (tryPutMVar gate ()))
        ( owned shared $ \session → do
            putMVar started ()
            takeMVar gate
            writeIORef finishedInFlight True
            pure (sessionBackend session)
        )
        $ \inFlight inFlightOutcome → do
          takeMVar started
          before ← queuedCount (sharedFixture shared)
          withForked (owned shared $ \session → writeIORef ranQueued True >> pure (sessionBackend session)) $ \queued queuedOutcome → do
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

-- | Run an action on an owned thread for the length of the body, which is given the thread and a wait for its outcome (#594).
-- However the scope ends, a return, a failure, a timeout of the example or a cancellation, the thread has ended and been
-- joined before it returns: the start is "Test.Support.Owned"'s, and the stop-and-join is not interruptible. The outcome is
-- the action's own, and a thread killed before it first ran has the outcome of being killed, as @forkFinally@ recorded it. The
-- wait ends when the thread does, so a body that waits for a thread nothing will end waits for ever, as it always did.
withForked ∷ IO a → (ThreadId → IO (Either SomeException a) → IO b) → IO b
withForked = withForkedOpening (pure ())

-- | 'withForked' for a thread held at a gate only the scope can open: the first argument is run, idempotently and without
-- blocking, in the uninterruptible release and before the kill, so a gate left closed by a failed example never holds the
-- join, a cancellation delivered as the scope begins included.
withForkedOpening ∷ IO () → IO a → (ThreadId → IO (Either SomeException a) → IO b) → IO b
withForkedOpening = withForkedIn ownedScope

-- | 'withForkedOpening' in a chosen kind of scope, for the ownership regressions' negative controls.
withForkedIn ∷ Scope → IO () → IO a → (ThreadId → IO (Either SomeException a) → IO b) → IO b
withForkedIn scope open action body = do
  finished ← newEmptyMVar
  startIn scope Unbound open (try action >>= putMVar finished) $ \thread ended →
    body thread (ended >> tryReadMVar finished >>= maybe (pure (Left (toException ThreadKilled))) pure)

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
