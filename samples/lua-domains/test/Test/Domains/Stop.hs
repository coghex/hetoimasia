-- | The stop paths and their cleanup evidence (#499 requirements 8 and 9): one stop of the session, from the driver,
-- that ends admission and grants, discards the in-flight tick, waits for a running segment, settles the gameplay
-- behavior, publishes one final snapshot, closes the publication and retires both owners; a cancellation of the
-- enclosing scope; and, for every way a session ends, one bounded evidence record that says every worker ended.
module Test.Domains.Stop (spec) where

import Control.Concurrent (killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Data.IORef (newIORef, readIORef, writeIORef)
import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (finally)
import Control.Monad (forM_, replicateM_, void, when)
import System.Exit (ExitCode (ExitFailure))
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Dispositions (..)
  , Domains (domainsShared)
  , DomainsConfig (configGameplaySource, configGameplaySpec, configInput, configTicks, configUiSeesEnd, configUiSource, configUiSpec)
  , Evidence (..)
  , GameSnapshot (snapDispositions, snapStatus, snapTick)
  , InstanceEvidence (..)
  , OwnerEvidence (..)
  , SessionReport (reportEvidence, reportStatus, reportTicks)
  , Placement
  , SessionStatus (Failed, Running, Stopped)
  , TickOutcome (TickFailed, TickHalted)
  , cleanupEvidence
  , exitStatusOf
  , runSession
  , stepTick
  , requestStop
  , stopSession
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Intention (Answer (Accepted))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedControls, sharedCounts))
import Hetoimasia.Sample.LuaDomains.Tally (ControlCounts (..), Counts (..), Workspaces (..), settledTotal)
import Hetoimasia.Scripting.Lua.Runtime (ExitKind (ExitCancelled, ExitStopped), ExitRecord (exitKind))
import Hetoimasia.Scripting.Lua.Scheduled (ScheduledSpec (scheduledObserve))
import Test.Domains.Support
import Test.Hspec
import Test.Support.Bounded (bounded)

placementsOf ∷ [Answer] → [Placement]
placementsOf answers = [place | Accepted place ← answers]

-- | How an owner's end reads: whether it ended, how, and what each of its instances came to.
shape ∷ OwnerEvidence → (Bool, Maybe ExitKind, [(Text, Text)])
shape owner = (evidenceEnded owner, exitKind <$> evidenceExit owner, [(evidenceInstance found, evidenceOutcome found) | found ← evidenceInstances owner])

-- | What every path leaves: both workers ended, the publication closed, nothing pending, and what the gameplay workspace
-- acquired it released, none of the releases failing.
leavesNothing ∷ Evidence → Expectation
leavesNothing evidence = do
  map evidenceEnded [evidenceUi evidence, evidenceGameplay evidence] `shouldBe` [True, True]
  evidencePublicationClosed evidence `shouldBe` True
  evidencePending evidence `shouldBe` 0
  (workspacesAcquired (evidenceWorkspaces evidence), workspacesReleased (evidenceWorkspaces evidence), workspacesReleaseFailed (evidenceWorkspaces evidence))
    `shouldSatisfy` (\(acquired, released, failed) → acquired == released && failed == 0)

failingHeld ∷ [Text]
failingHeld = ["function update(self, dt) fx.hold('held') error('failed at tick 1') end"]

-- | A UI that reads its receipts and asks to pause gameplay in each update, and says it has completed.
pausing ∷ [Text]
pausing = ["function update(self, dt) control.settle() control.pause() ui.updated() end"]

failingAtTwo ∷ [Text]
failingAtTwo =
  [ "function update(self, dt)"
  , "  if world.tick() == 2 then error('failed at tick 2') end"
  , "  staging.finish()"
  , "end"
  ]

spec ∷ Spec
spec = describe "the stop paths and the cleanup evidence" $ do
  it "stops between ticks: admission and grants end, what is pending is discarded, one final Stopped snapshot is published, and a repeated stop is harmless" $
    withSample (\config → config {configInput = []}) $ \_ _ domains → do
      forM_ [1 .. 3 ∷ Int] $ \_ → stepCommitted domains
      accepted ← mapM (offer domains) [0, 1, 2]
      _ ← stopSession domains
      (snapshot, revision) ← snapshotNow domains
      (snapTick snapshot, snapStatus snapshot, revision) `shouldBe` (3, Stopped, 4)
      dispDiscarded (snapDispositions snapshot) `shouldBe` placementsOf accepted
      stepTick domains >>= (`shouldSatisfy` isHalted)
      -- The evidence of a stop: both owners stopped in order, each instance stopped with no shutdown to run.
      evidence ← cleanupEvidence domains
      leavesNothing evidence
      shape (evidenceUi evidence) `shouldBe` (True, Just ExitStopped, [("interface", "stopped")])
      shape (evidenceGameplay evidence) `shouldBe` (True, Just ExitStopped, [("gameplay", "stopped")])
      balanced domains
      -- A repeated stop asks nothing again and publishes nothing.
      _ ← stopSession domains
      revisionNow domains `shouldReturn` 4

  it "stops a session that has already failed without overwriting the failure: it stays the reported status, and nothing is published" $
    withSample (\config → config {configInput = [], configGameplaySource = luaLines failingAtTwo}) $ \_ _ domains → do
      _ ← stepCommitted domains
      failed ← stepTick domains
      failure ← case failed of
        TickFailed snapshot → pure snapshot
        other → fail ("expected the session to fail, found " <> show other)
      revisionNow domains `shouldReturn` 2
      _ ← stopSession domains
      (latest, revision) ← snapshotNow domains
      (revision, latest) `shouldBe` (2, failure)
      snapStatus latest `shouldSatisfy` isFailed
      evidence ← cleanupEvidence domains
      leavesNothing evidence
      -- The failed instance is settled as failed, and the UI stopped.
      shape (evidenceGameplay evidence) `shouldBe` (True, Just ExitStopped, [("gameplay", "failed")])
      shape (evidenceUi evidence) `shouldBe` (True, Just ExitStopped, [("interface", "stopped")])
      balanced domains

  it "ends a clean run with evidence that both owners stopped in order, and with nothing left" $
    withSample (\config → config {configInput = [], configTicks = Just 2}) $ \_ _ domains → do
      report ← runSession domains
      let evidence = reportEvidence report
      leavesNothing evidence
      shape (evidenceUi evidence) `shouldBe` (True, Just ExitStopped, [("interface", "stopped")])
      shape (evidenceGameplay evidence) `shouldBe` (True, Just ExitStopped, [("gameplay", "stopped")])
      reportStatus report `shouldBe` Running
      balanced domains

  it "on cancellation of the enclosing scope while a tick is in flight, ends both owners cancelled, settles the instances as discarded, and hangs nothing" $ do
    fx ← newFx
    ui ← newFakeUi
    captured ← newEmptyMVar
    finished ← newEmptyMVar
    let config = (sampleConfig fx ui) {configGameplaySource = luaLines ["function update(self, dt) fx.hold('held') staging.finish() end"]}
    thread ← forkRegistered $ (withBoundary (\control → withDomains control config (\domains → putMVar captured domains >> stepCommitted domains >> pure ()))) `finally` putMVar finished ()
    domains ← bounded (readMVar captured)
    awaitEntered fx "held"
    -- Cancelled in the middle of the tick; a running segment is not preempted, so the owners end once it returns.
    killThread thread
    releaseGate fx "held"
    bounded (readMVar finished)
    evidence ← cleanupEvidence domains
    leavesNothing evidence
    -- The library decides how an owner that was cancelled records its exit: the cancellation also trips its
    -- stop token, and which of the two its loop sees first is a race, so an owner exits cancelled or stopped,
    -- and its instance is settled as discarded or stopped with it. What is fixed is that both ended.
    forM_ [evidenceUi evidence, evidenceGameplay evidence] $ \owner → do
      evidenceEnded owner `shouldBe` True
      (exitKind <$> evidenceExit owner) `shouldSatisfy` (`elem` [Just ExitCancelled, Just ExitStopped])
      map evidenceOutcome (evidenceInstances owner) `shouldSatisfy` all (`elem` ["discarded", "stopped"])
    revisionNow domains `shouldReturn` 0
    balanced domains
    counts ← readTVarIO (sharedCounts (domainsShared domains))
    countAccepted counts `shouldBe` settledTotal counts
  it "on cancellation of the enclosing scope with both owners held where the cancellation reaches them, ends both owners cancelled: the instances settle as discarded, and the exit records say so" $ do
    fx ← newFx
    ui ← newFakeUi
    armed ← newIORef False
    captured ← newEmptyMVar
    finished ← newEmptyMVar
    -- Each owner's own thread is held in Haskell, in the application's observer that runs before each of its segments,
    -- which a cancellation interrupts and which nothing else opens: the cancellation lands before the owner reaches its
    -- orderly stop check. A barrier inside a Lua callback would leave that order to the scheduler.
    let hold name owner = owner {scheduledObserve = \segment → do on ← readIORef armed; when on (holdAt fx name); scheduledObserve owner segment}
        config =
          (sampleConfig fx ui)
            { configGameplaySpec = hold "gameplay observer"
            , configUiSpec = hold "ui observer"
            , configGameplaySource = luaLines ["function update(self, dt) staging.finish() end"]
            }
    thread ← forkRegistered $ withBoundary (\control → withDomains control config (\domains → putMVar captured domains >> writeIORef armed True >> void (stepTick domains))) `finally` putMVar finished ()
    domains ← bounded (readMVar captured)
    tickUi domains ui
    awaitEntered fx "gameplay observer"
    awaitEntered fx "ui observer"
    killThread thread
    bounded (readMVar finished) `finally` mapM_ (releaseGate fx) ["gameplay observer", "ui observer"]
    evidence ← cleanupEvidence domains
    leavesNothing evidence
    forM_ [evidenceUi evidence, evidenceGameplay evidence] $ \owner → do
      evidenceEnded owner `shouldBe` True
      (exitKind <$> evidenceExit owner) `shouldBe` Just ExitCancelled
      map evidenceOutcome (evidenceInstances owner) `shouldBe` ["discarded"]
    revisionNow domains `shouldReturn` 0
    balanced domains
  it "overlaps a stop requested while a segment is held with the failure that segment then raises: the failure is the session's, published once, nothing is committed, and the ledger balances" $
    withSample (\config → config {configInput = [], configGameplaySource = luaLines ["function update(self, dt) fx.hold('held') error('failed while stopping') end"]}) $ \fx _ domains → withReleased fx ["held"] $ do
      offered ← mapM (offer domains) [0, 1]
      outcome ← driving domains (awaitEntered fx "held" >> requestStop domains >> waitFor (awaitClosed domains) >> releaseGate fx "held")
      _ ← stopSession domains
      outcome `shouldSatisfy` \case TickFailed _ → True; TickHalted → True; _ → False
      (snapshot, revision) ← snapshotNow domains
      (revision, snapTick snapshot, snapStatus snapshot) `shouldSatisfy` \(published, committed, status) → published == 1 && committed == 0 && isFailed status
      dispInvalidated (snapDispositions snapshot) `shouldBe` placementsOf offered
      evidence ← cleanupEvidence domains
      leavesNothing evidence
      balanced domains

  it "overlaps a pause accepted for the next tick with the failure of the current one: the failure is published once, the control is settled as no longer applicable and the UI observes it, and the controls balance" $ do
    fx ← newFx
    ui ← newFakeUi
    withBoundary $ \control →
      withDomains control ((sampleConfig fx ui) {configInput = [], configGameplaySource = luaLines failingHeld, configUiSource = luaLines pausing}) $ \domains → withReleased fx ["held"] $ do
        -- Tick one has begun, so the pause is for tick two, which will never run.
        outcome ← driving domains (awaitEntered fx "held" >> uiStep domains ui >> releaseGate fx "held")
        outcome `shouldSatisfy` \case TickFailed _ → True; _ → False
        stopServing domains ui
        counts ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted counts, controlNoLonger counts, controlApplied counts, controlAbandoned counts) `shouldBe` (1, 1, 0, 0)
        revisionNow domains `shouldReturn` 1
        balanced domains
  it "settles the gameplay instances at the end of a finite session before the publication closes: a shutdown that raises fails it, published after the last tick, and the executable's status says so" $
    withSample
      ( \config →
          config
            { configInput = []
            , configTicks = Just 3
            , configGameplaySource = luaLines ["function update(self, dt) staging.finish() end", "function shutdown(self, reason) error('shutdown failed') end"]
            }
      )
      $ \_ _ domains → do
        report ← runSession domains
        reportTicks report `shouldBe` 3
        reportStatus report `shouldSatisfy` isFailed
        exitStatusOf report `shouldBe` ExitFailure 1
        -- Three ticks, and one publication for the failure, with the world of the last tick frozen.
        (snapshot, revision) ← snapshotNow domains
        (revision, snapTick snapshot) `shouldBe` (4, 3)
        leavesNothing (reportEvidence report)
        balanced domains

  it "lets the surviving UI see the failure and the frozen world before the session ends" $ do
    fx ← newFx
    ui ← newFakeUi
    let seeing =
          [ "function update(self, dt)"
          , "  local status = view.status()"
          , "  ui.saw(status)"
          , "  fx.record('saw ' .. status .. ' at tick ' .. view.tick())"
          , "  ui.updated()"
          , "end"
          ]
        failingAtThree =
          [ "function update(self, dt)"
          , "  if world.tick() == 3 then error('failed at tick 3') end"
          , "  staging.finish()"
          , "end"
          ]
    withBoundary $ \control →
      withDomains control ((sampleConfig fx ui) {configInput = [], configUiSeesEnd = True, configGameplaySource = luaLines failingAtThree, configUiSource = luaLines seeing}) $ \domains → do
        replicateM_ 2 (stepCommitted domains)
        outcome ← stepTick domains
        outcome `shouldSatisfy` \case TickFailed _ → True; _ → False
        -- The session waits for the UI to see what ends it: the stop does not return while the UI has not run,
        -- however long it is given, and returns once the UI has run.
        finished ← newTVarIO False
        -- The stop is the application thread's; the UI runs from a thread of its own, once the stop has had every chance
        -- to return without it.
        _ ← alongside (replicateM_ 2000 yield >> (readTVarIO finished `shouldReturn` False) >> uiStep domains ui) (stopSession domains >> atomically (writeTVar finished True))
        -- The UI saw the last good tick beside the failure.
        fxLines fx >>= (`shouldSatisfy` elem "saw failed at tick 2")
        balanced domains
  where
    isHalted = \case
      TickHalted → True
      _ → False
    isFailed = \case
      Failed _ → True
      _ → False
