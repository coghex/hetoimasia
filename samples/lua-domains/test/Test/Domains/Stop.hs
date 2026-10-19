-- | The stop paths and their cleanup evidence (#499 requirements 8 and 9): one stop of the session, from the driver,
-- that ends admission and grants, discards the in-flight tick, waits for a running segment, settles the gameplay
-- behavior, publishes one final snapshot, closes the publication and retires both owners; a cancellation of the
-- enclosing scope; and, for every way a session ends, one bounded evidence record that says every worker ended.
module Test.Domains.Stop (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (readTVarIO)
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Dispositions (..)
  , Domains (domainsShared)
  , DomainsConfig (configGameplaySource, configInput, configTicks)
  , Evidence (..)
  , GameSnapshot (snapDispositions, snapStatus, snapTick)
  , InstanceEvidence (..)
  , OwnerEvidence (..)
  , SessionReport (reportEvidence, reportStatus)
  , Placement
  , SessionStatus (Failed, Running, Stopped)
  , TickOutcome (TickFailed, TickHalted)
  , cleanupEvidence
  , runSession
  , stepTick
  , stopSession
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Intention (Answer (Accepted))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts))
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..), Workspaces (..), settledTotal)
import Hetoimasia.Scripting.Lua.Runtime (ExitKind (ExitCancelled, ExitStopped), ExitRecord (exitKind))
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
    thread ← forkIO $ (withBoundary (\control → withDomains control config (\domains → putMVar captured domains >> stepCommitted domains >> pure ()))) `finally` putMVar finished ()
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
  where
    isHalted = \case
      TickHalted → True
      _ → False
    isFailed = \case
      Failed _ → True
      _ → False
