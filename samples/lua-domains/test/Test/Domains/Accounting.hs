-- | The driver's decisions rest on the owner's accounting, not on a task of the sample's own (#499 requirements 2, 4 and
-- 8, D-47): a tick is committed, and a stop's outcome is decided, only after the owner has accounted for the endings the
-- work caused, whatever the session holds; the accounting wait is made one at a time; the sample's own bookkeeping
-- (admitted tasks, issued stops, the final publication) survives a cancellation at each window the examples can open
-- with a gate; and a failed session is quiescent before its failure is published.
module Test.Domains.Accounting (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Concurrent.STM (readTVar, readTVarIO, retry)
import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, replicateM_, void, when)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundSessionTasks)
  , Domains (domainsGameplay, domainsShared)
  , DomainsDefect (StopOffApplicationThread)
  , DomainsConfig (..)
  , Evidence (evidenceGameplay)
  , Extension (Extension)
  , GameSnapshot (snapStatus, snapTick)
  , InstanceEvidence (evidenceInstance, evidenceOutcome)
  , OwnerEvidence (evidenceEnded, evidenceInstances)
  , PublishPoint (AfterClaim, BeforeClaim)
  , SessionStatus (Failed, Stopped)
  , StopPoint (StopIntended, StopIssued)
  , Started (startedOwner)
  , Where (InGameplay)
  , TickOutcome (TickCommitted, TickFailed, TickHalted)
  , admitGameplayTask
  , cleanupEvidence
  , defaultBounds
  , requestStop
  , stepTick
  , stopSession
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Bounds (maxSessionTasks)
import Hetoimasia.Sample.LuaDomains.Scripts (moduleSource)
import Hetoimasia.Sample.LuaDomains.Session (SessionState (sessionFailureCount))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCommitted, sharedSession, sharedStopsIssued, sharedTaskAdmitting, sharedWaitDepth, sharedWaitThreads))
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure (..))
import Hetoimasia.Scripting.Lua.Instance (InstanceKind (RunOnce), InstanceRequest (..))
import Hetoimasia.Scripting.Lua.Owner (EntryPoint (EntryPoint), ModuleRef (ModuleRef), ModuleSource, Requirement (Required))
import Hetoimasia.Scripting.Lua.Registration (WaitKind (WaitLogical), namespace, waitOperation, yieldOperation)
import Hetoimasia.Scripting.Lua.Scheduled
  ( ServiceClass (OrdinaryClass)
  , TaskAdmission (TaskAccepted, TaskAdmissionClosed)
  , TaskKind (OneShot)
  , TaskRequest (..)
  , scheduledEndpoint
  , ticksOutstanding
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger))
import Test.Domains.Support
import Test.Hspec

evidenceOf ∷ GameSnapshot → Maybe FailureEvidence
evidenceOf snapshot = case snapStatus snapshot of
  Failed found → Just found
  _ → Nothing

expectFailed ∷ TickOutcome → IO GameSnapshot
expectFailed = \case
  TickFailed snapshot → pure snapshot
  other → throwIO (userError ("expected the session to fail, found " <> show other))

-- | The scheduler's wait operation in the gameplay VM, for the instances and tasks that wait for ticks.
withWait ∷ DomainsConfig → DomainsConfig
withWait config = config {configExtensions = \shared → configExtensions config shared <> [Extension (namespace "sched" [waitOperation "wait_ticks" WaitLogical [SInteger], yieldOperation "yield"]) InGameplay []]}

gameplayWith ∷ [Text] → ByteString
gameplayWith = luaLines

extraModule ∷ [Text] → ModuleSource
extraModule source = moduleSource "extra" (luaLines source)

-- | An instance of the module @extra@ that runs once, under this name.
peer ∷ Text → InstanceRequest
peer name = InstanceRequest (ModuleRef "extra" "1") RunOnce (Just name) OrdinaryClass []

task ∷ Text → Text → TaskRequest
task name entry = TaskRequest (ModuleRef "gameplay" "1") entry [] OrdinaryClass OneShot (Just name)

accepted ∷ TaskAdmission → Bool
accepted = \case
  TaskAccepted _ _ → True
  _ → False

taskEntries ∷ [EntryPoint]
taskEntries = [EntryPoint "task_runs" Required [] [], EntryPoint "task_fails" Required [] [], EntryPoint "task_waits" Required [] []]

taskFunctions ∷ [Text]
taskFunctions = ["function task_runs() fx.record('task ran') end", "function task_fails() error('task failed') end", "function task_waits() sched.wait_ticks(1000000) end"]

spec ∷ Spec
spec = describe "the owner's accounting, and what the sample's own bookkeeping survives" $ do
  describe "a tick's commit and a stop's outcome are decided after the owner's accounting" $ do
    it "holds a tick whose grant has completed while the escalation of its failure is still pending: nothing is committed or published until it has returned, and then the failure is" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (withWait (sampleConfig fx ui))
            { configInput = []
            , -- A wait the scheduler refuses ends the instance after the grant has completed: the instance layer accounts
              -- for it, and tells the application, later.
              configGameplaySource = gameplayWith ["function update(self, dt) staging.move(0, 1, 0) staging.finish() sched.wait_ticks(0) end"]
            , configEscalateHook = holdAt fx "escalating"
            }
          $ \domains → withReleased fx ["escalating"] $ do
            lastGood ← readTVarIO (sharedCommitted (domainsShared domains))
            collect ← spawn (stepTick domains)
            awaitEntered fx "escalating"
            -- The tick has completed, as the scheduler counts: what is pending is the owner's accounting of the failure.
            waitFor (ticksOutstanding (scheduledEndpoint (startedOwner (domainsGameplay domains))) >>= \outstanding → when (outstanding > 0) retry)
            replicateM_ 2000 yield
            revisionNow domains `shouldReturn` 0
            readTVarIO (sharedCommitted (domainsShared domains)) `shouldReturn` lastGood
            releaseGate fx "escalating"
            snapshot ← collect >>= expectFailed
            snapTick snapshot `shouldBe` 0
            fmap (failKind . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "refused wait"
            revisionNow domains `shouldReturn` 1
            readTVarIO (sharedCommitted (domainsShared domains)) `shouldReturn` lastGood

    it "holds a stop's outcome while the escalation of a shutdown that raised is still pending, though the instance has settled: the outcome is the failure" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (sampleConfig fx ui)
            { configInput = []
            , configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end", "function shutdown(self, reason) error('shutdown failed') end"]
            , configEscalateHook = holdAt fx "escalating"
            }
          $ \domains → withReleased fx ["escalating"] $ do
            _ ← alongside (awaitEntered fx "escalating" >> replicateM_ 2000 yield >> (revisionNow domains `shouldReturn` 0) >> releaseGate fx "escalating") (stopSession domains)
            (snapshot, revision) ← snapshotNow domains
            revision `shouldBe` 1
            fmap (failStage . evidencePrimary) (failedEvidence snapshot) `shouldBe` Just "shutdown"

  describe "the supervised waits the sample makes" $ do
    it "are made on the application thread, one at a time: a stop requested while the driver's accounting wait is pending waits for no wait of its own" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (sampleConfig fx ui)
            { configInput = []
            , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"]
            , configEscalateHook = holdAt fx "escalating"
            }
          $ \domains → withReleased fx ["escalating"] $ do
            home ← myThreadId
            -- The driver is the application thread's; the stop is asked for from another, which waits for nothing.
            _ ← alongside (awaitEntered fx "escalating" >> requestStop domains >> waitFor (awaitClosed domains) >> replicateM_ 2000 yield >> releaseGate fx "escalating") (stepTick domains)
            _ ← stopSession domains
            (_, most) ← readTVarIO (sharedWaitDepth (domainsShared domains))
            most `shouldBe` 1
            readTVarIO (sharedWaitThreads (domainsShared domains)) `shouldReturn` Set.singleton home

    it "are taken in turn when the driver runs on a thread of its own: the stop's wait does not begin beside the driver's" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (sampleConfig fx ui)
            { configInput = []
            , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"]
            , configEscalateHook = holdAt fx "escalating"
            }
          $ \domains → withReleased fx ["escalating"] $ do
            collect ← spawn (stepTick domains)
            awaitEntered fx "escalating"
            _ ← alongside (waitFor (awaitClosed domains) >> replicateM_ 2000 yield >> releaseGate fx "escalating") (stopSession domains)
            _ ← collect
            (_, most) ← readTVarIO (sharedWaitDepth (domainsShared domains))
            most `shouldBe` 1

    it "are refused to a stop from another thread, which asks through requestStop and finalizes nothing" $
      withSample (\config → config {configInput = []}) $ \_ _ domains → do
        outcome ← spawn (stopSession domains)
        try @SomeException outcome >>= (`shouldSatisfy` \case Left failure → fromException failure == Just StopOffApplicationThread; Right _ → False)
        requestStop domains
        revisionNow domains `shouldReturn` 0
        _ ← stopSession domains
        (snapshot, revision) ← snapshotNow domains
        (revision, snapStatus snapshot) `shouldBe` (1, Stopped)

  describe "the gameplay owner's capacity" $
    forM_ [1, boundSessionTasks defaultBounds, maxSessionTasks] $ \limit →
      it ("leaves the update a slot with " <> show limit <> " suspended tasks held and every instance live and suspended: the tick reaches its commit decision, and a stop completes") $ do
        let peers = [peer "peer one", peer "peer two", peer "peer three"]
        withSample
          ( \config →
              (withWait config)
                { configBounds = (configBounds config) {boundSessionTasks = limit}
                , configInput = []
                , configGameplaySource = gameplayWith ("function update(self, dt) staging.finish() end" : taskFunctions)
                , configGameplayEntries = taskEntries
                , configGameplayInstances = peers
                , configGameplayModules = [extraModule ["function run(self) sched.wait_ticks(1000000) end"]]
                }
          )
          $ \_ _ domains → do
            admitted ← forM [1 .. limit] $ \_ → admitGameplayTask domains (task "waiting task" "task_waits")
            map accepted admitted `shouldBe` replicate limit True
            -- Every task is suspended and holds its slot, every peer is suspended in its run and holds one, and the
            -- behavior's update is due: the owner has a slot for each.
            stepTick domains >>= (`shouldSatisfy` \case TickCommitted _ → True; _ → False)
            void (stopSession domains)
            (snapshot, _) ← snapshotNow domains
            snapStatus snapshot `shouldBe` Stopped

  describe "the gameplay owner's capacity at a stop" $
    forM_ [1, boundSessionTasks defaultBounds, maxSessionTasks] $ \limit →
      it ("leaves every instance's shutdown a slot with " <> show limit <> " suspended tasks held: a stop with no tick between completes, and settles the tasks") $
        withSample
          ( \config →
              (withWait config)
                { configBounds = (configBounds config) {boundSessionTasks = limit}
                , configInput = []
                , configGameplaySource = gameplayWith ("function update(self, dt) staging.finish() end" : "function shutdown(self, reason) fx.record('gameplay shutdown') end" : taskFunctions)
                , configGameplayEntries = taskEntries
                , configGameplayInstances = [peer "peer one", peer "peer two", peer "peer three"]
                , configGameplayModules = [extraModule ["function run(self) sched.wait_ticks(1000000) end", "function shutdown(self, reason) fx.record('peer shutdown') end"]]
                }
          )
          $ \fx _ domains → do
            admitted ← forM [1 .. limit] $ \_ → admitGameplayTask domains (task "waiting task" "task_waits")
            map accepted admitted `shouldBe` replicate limit True
            stopBounded domains
            fxLines fx >>= \recorded → (length (filter (== "peer shutdown") recorded), length (filter (== "gameplay shutdown") recorded)) `shouldBe` (3, 1)
            heldTasks domains `shouldReturn` 0
            (snapshot, _) ← snapshotNow domains
            snapStatus snapshot `shouldBe` Stopped

  describe "an admission cancelled" $ do
    it "before the owner is asked leaves nothing behind: nothing is accepted or counted, and the next admission and a stop go on" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (withWait (sampleConfig fx ui))
            { configInput = []
            , configGameplaySource = gameplayWith ("function update(self, dt) staging.finish() end" : taskFunctions)
            , configGameplayEntries = taskEntries
            , configTaskHook = holdAt fx "before the owner"
            }
          $ \domains → withReleased fx ["before the owner"] $ do
            let shared = domainsShared domains
            ended ← newEmptyMVar
            admitter ← forkIO (try @SomeException (admitGameplayTask domains (task "cancelled" "task_runs")) >>= putMVar ended)
            awaitEntered fx "before the owner"
            killThread admitter
            _ ← generous (readMVar ended)
            heldTasks domains `shouldReturn` 0
            readTVarIO (sharedTaskAdmitting shared) `shouldReturn` 0
            releaseGate fx "before the owner"
            admitGameplayTask domains (task "next" "task_runs") >>= (`shouldSatisfy` accepted)
            heldTasks domains `shouldReturn` 1
            stopBounded domains
            heldTasks domains `shouldReturn` 0
            (snapshot, _) ← snapshotNow domains
            snapStatus snapshot `shouldBe` Stopped

    forM_ [("a suspended task", "task_waits", False), ("a task that faults", "task_fails", True)] $ \(label, entry, faults) →
      it ("after the owner accepted " <> label <> " leaves it tracked and counted: it is held until it settles, a fault is told once, a stop settles the rest, and no reservation is lost") $ do
        fx ← newFx
        ui ← newFakeUi
        withBoundary $ \control →
          withDomains
            control
            (withWait (sampleConfig fx ui))
              { configInput = []
              , configGameplaySource = gameplayWith ("function update(self, dt) staging.finish() end" : taskFunctions)
              , configGameplayEntries = taskEntries
              , configHandoffHook = holdAt fx "accepted"
              }
            $ \domains → withReleased fx ["accepted"] $ do
              let shared = domainsShared domains
              ended ← newEmptyMVar
              admitter ← forkIO (try @SomeException (admitGameplayTask domains (task "cancelled task" entry)) >>= putMVar ended)
              awaitEntered fx "accepted"
              killThread admitter
              _ ← generous (readMVar ended)
              readTVarIO (sharedTaskAdmitting shared) `shouldReturn` 0
              if faults
                then -- The owner accepted it and the session tracks it, though the admitter never returned: its watcher tells
                  -- the fault, which nothing else would if the task were not tracked.
                  waitFor (readTVar (sharedSession shared) >>= \state → when (sessionFailureCount state < 1) retry)
                else heldTasks domains `shouldReturn` 1
              releaseGate fx "accepted"
              stopBounded domains
              sessionFailureCount <$> readTVarIO (sharedSession shared) >>= (`shouldBe` (if faults then 1 else 0))
              heldTasks domains `shouldReturn` 0
              (snapshot, _) ← snapshotNow domains
              snapStatus snapshot `shouldSatisfy` \case Failed _ → faults; Stopped → not faults; _ → False
              admitGameplayTask domains (task "late" "task_runs") >>= (`shouldSatisfy` \case TaskAdmissionClosed → True; _ → False)

  describe "a stop cancelled" $
    forM_ [("after its intent is recorded and before it has asked any instance", StopIntended, []), ("after it asked the first instance to stop", StopIssued 0, [0])] $ \(label, point, issued) →
      it ("" <> label <> " has issued the stops it asked for and tracks them: a second stop asks only for the instances not yet asked, and teardown completes") $ do
        fx ← newFx
        ui ← newFakeUi
        seen ← newIORef []
        let hook reached = do
              atomicModifyIORef' seen (\held → (held <> [reached], ()))
              when (reached == point) (holdAt fx "stop held")
        withBoundary $ \control →
          withDomains
            control
            (withWait (sampleConfig fx ui))
              { configInput = []
              , configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end"]
              , configGameplayInstances = [peer "peer one", peer "peer two"]
              , configGameplayModules = [extraModule ["function run(self) sched.wait_ticks(1000000) end"]]
              , configStopHook = hook
              }
            $ \domains → withReleased fx ["stop held"] $ do
              -- The first stop is the application thread's own call, cancelled where it is held.
              first ← cancelWhen (awaitEntered fx "stop held") (stopSession domains)
              first `shouldSatisfy` isNothing
              -- What the first stop asked for is remembered, whoever was interrupted.
              readTVarIO (sharedStopsIssued (domainsShared domains)) `shouldReturn` issued
              releaseGate fx "stop held"
              stopBounded domains
              -- Each instance was asked once, in all.
              asked ← readIORef seen
              [position | StopIssued position ← asked] `shouldBe` [0, 1, 2]
              (snapshot, revision) ← snapshotNow domains
              (revision, snapStatus snapshot) `shouldBe` (1, Stopped)
              evidence ← cleanupEvidence domains
              evidenceEnded (evidenceGameplay evidence) `shouldBe` True

  describe "a publication cancelled before it is made" $ do
    it "before the ending is claimed leaves it to the next caller: a stop publishes the failure once" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (sampleConfig fx ui)
            { configInput = []
            , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"]
            , configPublishHook = \point → when (point == BeforeClaim) (holdAt fx "before the claim")
            }
          $ \domains → withReleased fx ["before the claim"] $ do
            ended ← newEmptyMVar
            driver ← forkIO (try @SomeException (stepTick domains) >>= putMVar ended)
            awaitEntered fx "before the claim"
            killThread driver
            _ ← generous (readMVar ended)
            releaseGate fx "before the claim"
            revisionNow domains `shouldReturn` 0
            stopBounded domains
            (snapshot, revision) ← snapshotNow domains
            revision `shouldBe` 1
            fmap (failStage . evidencePrimary) (failedEvidence snapshot) `shouldBe` Just "update"
    it "after the ending is claimed ends the session, so no later caller waits for ever, and the owners retire" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (sampleConfig fx ui)
            { configInput = []
            , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"]
            , configPublishHook = \point → when (point == AfterClaim) (holdAt fx "claimed")
            }
          $ \domains → withReleased fx ["claimed"] $ do
            ended ← newEmptyMVar
            driver ← forkIO (try @SomeException (stepTick domains) >>= putMVar ended)
            awaitEntered fx "claimed"
            killThread driver
            _ ← generous (readMVar ended)
            releaseGate fx "claimed"
            stopBounded domains
            evidence ← cleanupEvidence domains
            evidenceEnded (evidenceGameplay evidence) `shouldBe` True

  describe "what a failure and a stop ask for before they wait" $ do
    let ready = "function run(self) sched.wait_ticks(1) while true do sched.yield() end end"
    it "has an instance's failure ask a surviving instance that stays ready after yielding to stop, so the failed tick completes and its failure is published" $
      withSample
        ( \config →
            (withWait config)
              { configInput = []
              , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"]
              , configGameplayInstances = [peer "ready peer"]
              , configGameplayModules = [extraModule [ready]]
              }
        )
        $ \_ _ domains → do
          snapshot ← generous (stepTick domains) >>= expectFailed
          fmap (failStage . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "update"
          evidence ← cleanupEvidence domains
          sort [(evidenceInstance found, evidenceOutcome found) | found ← evidenceInstances (evidenceGameplay evidence)] `shouldBe` [("gameplay", "failed"), ("ready peer", "stopped")]
    it "has a task's fault ask a surviving instance that stays ready after yielding to stop, as soon as the fault is told, though the driver is waiting for the tick the instance keeps outstanding" $
      withSample
        ( \config →
            (withWait config)
              { configInput = []
              , configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end", "function task_fails() error('task failed') end"]
              , configGameplayEntries = [EntryPoint "task_fails" Required [] []]
              , configGameplayInstances = [peer "ready peer"]
              , configGameplayModules = [extraModule [ready]]
              }
        )
        $ \_ _ domains → do
          collect ← spawn (stepTick domains)
          waitFor (ticksOutstanding (scheduledEndpoint (startedOwner (domainsGameplay domains))) >>= \outstanding → when (outstanding < 1) retry)
          _ ← admitGameplayTask domains (task "faulting task" "task_fails")
          snapshot ← collect >>= expectFailed
          fmap (failWho . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "faulting task"
    forM_ ["a concurrent stop request", "a stop after the driver was cancelled"] $ \how →
      it ("has " <> how <> " ask an instance that wakes on the tick and stays ready after yielding to stop, though the driver is waiting for the tick it keeps outstanding") $ do
        fx ← newFx
        ui ← newFakeUi
        withBoundary $ \control →
          withDomains
            control
            (withWait (sampleConfig fx ui))
              { configInput = []
              , configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end"]
              , configGameplayInstances = [peer "ready peer"]
              , configGameplayModules = [extraModule [ready]]
              }
            $ \domains → do
              ended ← newEmptyMVar
              driver ← forkIO (try @SomeException (stepTick domains) >>= putMVar ended)
              -- The peer has woken on the tick and keeps it outstanding: the driver is in its wait for the tick, and
              -- nothing ends the wait by itself.
              waitFor (ticksOutstanding (scheduledEndpoint (startedOwner (domainsGameplay domains))) >>= \outstanding → when (outstanding < 1) retry)
              replicateM_ 2000 yield
              tryReadMVar ended >>= (`shouldSatisfy` isNothing)
              if how == "a stop after the driver was cancelled"
                then killThread driver >> void (generous (readMVar ended)) >> void (generous (stopSession domains))
                else do
                  requestStop domains
                  outcome ← generous (readMVar ended)
                  -- The driver's tick was halted by the stop, which freed it, and committed nothing.
                  either (const Nothing) Just outcome `shouldSatisfy` \case Just TickHalted → True; _ → False
                  void (generous (stopSession domains))
              (snapshot, _) ← snapshotNow domains
              (snapTick snapshot, snapStatus snapshot) `shouldBe` (0, Stopped)

  describe "a failed session" $
    it "has stopped every surviving instance before its failure is published, one with work still to run among them: each is settled and its shutdown has run, and the owner stays alive" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (withWait (sampleConfig fx ui))
            { configInput = []
            , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"]
            , configGameplayInstances = [peer "peer"]
            , configGameplayModules =
                [ extraModule
                    [ "function run(self) while true do fx.record('peer ran') sched.wait_ticks(1) end end"
                    , "function shutdown(self, reason) fx.record('peer shutdown') end"
                    ]
                ]
            }
          $ \domains → do
            snapshot ← stepTick domains >>= expectFailed
            fmap (failStage . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "update"
            -- Nothing is awaited: the failure was published after the peer had settled and run its shutdown.
            fxLines fx >>= (`shouldSatisfy` elem "peer shutdown")
            evidence ← cleanupEvidence domains
            sort [(evidenceInstance found, evidenceOutcome found) | found ← evidenceInstances (evidenceGameplay evidence)] `shouldBe` [("gameplay", "failed"), ("peer", "stopped")]
            evidenceEnded (evidenceGameplay evidence) `shouldBe` False
            ranThen ← length . filter (== "peer ran") <$> fxLines fx
            replicateM_ 2000 yield
            ranNow ← length . filter (== "peer ran") <$> fxLines fx
            ranNow `shouldBe` ranThen
