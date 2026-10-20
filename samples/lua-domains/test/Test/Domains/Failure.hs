-- | The failure of the gameplay session (#499 requirements 1 to 4): any failure of script execution on the gameplay
-- owner fails the session; the session is then quiescent, with the last good world and committed tick; the failure is
-- published once beside them; and the driver learns of a failure in tick T before it decides T's commit, on every
-- ordering the examples can force with gates.
module Test.Domains.Failure (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (SomeException, throwIO, try)
import Control.Concurrent (yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Monad (forM, forM_, join, replicateM_, when)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerLive))
import Hetoimasia.Sample.LuaDomains
  ( Answer (Closed)
  , Domains (domainsControl, domainsGameplay, domainsShared)
  , DomainsConfig (configBounds, configInput, configPublishHook, configTaskHook, configExtensions, configGameplayEntries, configGameplayInstances, configGameplayModules, configGameplaySource)
  , Evidence (evidenceAfter, evidenceFailures, evidenceGameplay)
  , Extension (Extension)
  , GameSnapshot (snapStatus, snapTick, snapWorld)
  , OwnerEvidence (evidenceEnded)
  , PublishPoint (AfterClaim, BeforeClaim)
  , SessionStatus (Failed, Stopped)
  , Started (startedOwner)
  , TickOutcome (TickCommitted, TickFailed, TickHalted)
  , Where (InGameplay)
  , admitGameplayTask
  , cleanupEvidence
  , Bounds (boundSessionTasks)
  , defaultBounds
  , requestStop
  , stepTick
  , stopSession
  , tellTask
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Bounds (maxSessionTasks)
import Hetoimasia.Sample.LuaDomains.Scripts (moduleSource)
import Hetoimasia.Sample.LuaDomains.Session (SessionState (sessionFailureCount, sessionFailures))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCommitted, sharedSession, sharedTick), Watched (Watched), failSession)
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure (..))
import Hetoimasia.Sample.LuaDomains.World (initialWorld)
import Hetoimasia.Scripting.Lua.Instance (InstanceKind (EventOnly, RunOnce), InstanceRequest (..))
import Hetoimasia.Scripting.Lua.Owner (EntryPoint (EntryPoint), ModuleRef (ModuleRef), ModuleSource, Requirement (Required))
import Hetoimasia.Scripting.Lua.Registration (WaitKind (WaitLogical), namespace, stateOperation, waitOperation)
import Hetoimasia.Scripting.Lua.Scheduled
  ( ScheduledOutcome (SettledFaulted)
  , ScheduledOwner
  , ScheduledSettlement (settledOutcome)
  , ServiceClass (OrdinaryClass)
  , TaskAdmission (TaskAccepted, TaskAdmissionClosed, TaskQueueFull)
  , TaskKind (OneShot)
  , TaskRequest (..)
  , awaitTask
  , scheduledEndpoint
  , scheduledStatus
  , scheduledTick
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger))
import Test.Domains.Support
import Test.Hspec

-- | The failure a snapshot publishes, if it publishes one.
evidenceOf ∷ GameSnapshot → Maybe FailureEvidence
evidenceOf snapshot = case snapStatus snapshot of
  Failed found → Just found
  _ → Nothing

-- | A tick that must fail the session: the snapshot published for the failure.
expectFailed ∷ TickOutcome → IO GameSnapshot
expectFailed = \case
  TickFailed snapshot → pure snapshot
  other → throwIO (userError ("expected the session to fail, found " <> show other))

-- | Add the scheduler's wait operation to the gameplay VM, which an example needs to have one refused.
withWait ∷ DomainsConfig → DomainsConfig
withWait config = config {configExtensions = \shared → configExtensions config shared <> [Extension (namespace "sched" [waitOperation "wait_ticks" WaitLogical [SInteger]]) InGameplay []]}

-- | Gameplay's behavior calls a binding whose action raises: a failure of the application's own code.
withBoom ∷ DomainsConfig → DomainsConfig
withBoom config =
  config
    { configGameplaySource = gameplayWith ["function update(self, dt) boom.fail() end"]
    , configExtensions = \shared → configExtensions config shared <> [Extension (namespace "boom" [stateOperation "fail" [] [] (\_ → throwIO (userError "the binding failed"))]) InGameplay []]
    }

-- | The gameplay owner, which a failed session leaves alive.
gameplayOwner ∷ Domains → ScheduledOwner
gameplayOwner = startedOwner . domainsGameplay

-- | An instance that runs once: its module's @run@, whatever the example makes it.
oneShot ∷ InstanceRequest
oneShot = InstanceRequest (ModuleRef "extra" "1") RunOnce (Just "one-shot") OrdinaryClass []

-- | An event-only instance, which does nothing until it is stopped.
bystander ∷ InstanceRequest
bystander = InstanceRequest (ModuleRef "extra" "1") EventOnly (Just "bystander") OrdinaryClass []

extraModule ∷ [Text] → ModuleSource
extraModule source = moduleSource "extra" (luaLines source)

gameplayWith ∷ [Text] → ByteString
gameplayWith = luaLines

spec ∷ Spec
spec = describe "the failure of the gameplay session" $ do
  describe "a script failure fails the session" $ do
    it "is the failure of an update: nothing is committed, the failure is published once beside the last good snapshot, and the session is quiescent" $
      withSample (\config → config {configGameplaySource = gameplayWith ["function update(self, dt) staging.move(0, 1, 0) error('update failed') end"]}) $ \_ _ domains → do
        lastGood ← readTVarIO (sharedCommitted (domainsShared domains))
        snapshot ← stepTick domains >>= expectFailed
        -- The last good world and committed tick, and one publication for the failure.
        (snapTick snapshot, snapWorld snapshot) `shouldBe` (0, lastGood)
        revisionNow domains `shouldReturn` 1
        readTVarIO (sharedCommitted (domainsShared domains)) `shouldReturn` lastGood
        readTVarIO (sharedTick (domainsShared domains)) >>= (`shouldSatisfy` null)
        case evidenceOf snapshot of
          Nothing → expectationFailure "the snapshot does not say the session failed"
          Just found → do
            let primary = evidencePrimary found
            (failWho primary, failStage primary, failTick primary, failKind primary) `shouldBe` ("gameplay", "update", 1, "script error")
            Text.unpack (failMessage primary) `shouldSatisfy` ("update failed" `isInfixOf`)
            evidenceLater found `shouldBe` 0
        -- Quiescent: no tick begins, nothing more is published, nothing is granted, and the owner stays alive.
        granted ← atomically (scheduledTick (scheduledEndpoint (gameplayOwner domains)))
        forM_ [1 .. 3 ∷ Int] $ \_ → stepTick domains >>= (`shouldSatisfy` isHalted)
        revisionNow domains `shouldReturn` 1
        atomically (scheduledTick (scheduledEndpoint (gameplayOwner domains))) `shouldReturn` granted
        evidence ← cleanupEvidence domains
        evidenceEnded (evidenceGameplay evidence) `shouldBe` False
        atomically (scheduledStatus (gameplayOwner domains)) >>= (`shouldSatisfy` isLive)

    it "is the failure of an init, before the first tick: the initial world and committed tick zero, published beside it" $
      withSample (\config → config {configGameplaySource = gameplayWith ["function init(self, api) error('init failed') end", "function update(self, dt) staging.finish() end"]}) $ \_ _ domains → do
        (snapshot, _) ← snapshotNow domains
        snapTick snapshot `shouldBe` 0
        snapWorld snapshot `shouldBe` initialWorld defaultBounds 1 1
        revisionNow domains `shouldReturn` 1
        fmap (failStage . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "init"
        fmap (failTick . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just 0
        stepTick domains >>= (`shouldSatisfy` isHalted)
        revisionNow domains `shouldReturn` 1

    it "is the failure of a one-shot's run, an instance beside the behavior" $
      withSample
        ( \config →
            config
              { configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end"]
              , configGameplayInstances = [oneShot]
              , configGameplayModules = [extraModule ["function run(self) error('run failed') end"]]
              }
        )
        $ \_ _ domains → do
          -- The driver publishes the failure: at the start if it was told of it then, and otherwise when it acts, with the
          -- tick it then begins failed and not committed.
          outcome ← stepTick domains
          outcome `shouldSatisfy` \case TickFailed _ → True; TickHalted → True; _ → False
          (snapshot, _) ← snapshotNow domains
          fmap (failStage . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "run"
          fmap (failWho . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "one-shot"
          stepTick domains >>= (`shouldSatisfy` isHalted)

    it "is the fault of a task the session admitted" $
      withSample
        ( \config →
            config
              { configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end", "function task_fails() error('task failed') end"]
              , configGameplayEntries = [EntryPoint "task_fails" Required [] []]
              }
        )
        $ \_ _ domains → do
          admitted ← admitGameplayTask domains (TaskRequest (ModuleRef "gameplay" "1") "task_fails" [] OrdinaryClass OneShot (Just "faulting task"))
          case admitted of
            TaskAccepted _ _ → pure ()
            other → expectationFailure ("the task was not admitted: " <> show other)
          snapshot ← stepTick domains >>= expectFailed
          fmap (\found → (failWho found, failStage found)) (evidencePrimary <$> evidenceOf snapshot) `shouldBe` Just ("faulting task", "task")
          -- The failing tick committed nothing.
          snapTick snapshot `shouldBe` 0

    it "is not a failure of application code, which stays an owner failure under supervision and publishes no failed status" $ do
      fx ← newFx
      ui ← newFakeUi
      facts ← newIORef Nothing
      -- The supervision boundary rethrows the failure it latched when it closes, so the facts are gathered inside it.
      _ ←
        try @SomeException . withBoundary $ \control →
          withDomains control (withBoom (sampleConfig fx ui)) $ \domains → do
            _ ← try @SomeException (stepTick domains)
            (snapshot, revision) ← snapshotNow domains
            count ← sessionFailureCount <$> readTVarIO (sharedSession (domainsShared domains))
            writeIORef facts (Just (snapTick snapshot, isNothing (evidenceOf snapshot), revision, count))
      readIORef facts `shouldReturn` Just (0, True, 0, 0)

  describe "a failure is known before the tick's commit is decided" $ do
    it "is raised in the last segment of a tick, after the work was said to be done" $
      withSample (\config → config {configGameplaySource = gameplayWith ["function update(self, dt) staging.move(0, 1, 0) staging.finish() error('late failure') end"]}) $ \_ _ domains → do
        snapshot ← stepTick domains >>= expectFailed
        snapTick snapshot `shouldBe` 0
        fmap (failMessage . evidencePrimary) (evidenceOf snapshot) `shouldSatisfy` maybe False (("late failure" `isInfixOf`) . Text.unpack)
        revisionNow domains `shouldReturn` 1

    it "is two failures in one tick: the first is the session's, the second, a surviving instance's shutdown that raises as the failure asks it to stop, is counted beside it" $
      withSample
        ( \config →
            config
              { configGameplaySource = gameplayWith ["function update(self, dt) fx.hold('both') error('behavior failed') end"]
              , configGameplayInstances = [bystander]
              , configGameplayModules = [extraModule ["function shutdown(self, reason) error('bystander shutdown failed') end"]]
              }
        )
        $ \fx _ domains → withReleased fx ["both"] $ do
          snapshot ← driving domains (awaitEntered fx "both" >> releaseGate fx "both") >>= expectFailed
          -- Both are the session's, in the tick they happened in; the behavior's is first, and the other is counted.
          fmap evidenceLater (evidenceOf snapshot) `shouldBe` Just 1
          held ← sessionFailures <$> readTVarIO (sharedSession (domainsShared domains))
          map failWho held `shouldBe` ["gameplay", "bystander"]
          revisionNow domains `shouldReturn` 1

    it "is a scheduler-refused wait in the tick's final segment, with a gated shutdown: nothing is committed or published until the failure has settled" $
      withSample
        ( \config →
            withWait
              config
                { configGameplaySource =
                    gameplayWith
                      [ "function update(self, dt) staging.move(0, 1, 0) staging.finish() sched.wait_ticks(0) end"
                      , "function shutdown(self, reason) fx.hold('shutdown') fx.record('shutdown ' .. reason) end"
                      ]
                }
        )
        $ \fx _ domains → withReleased fx ["shutdown"] $ do
          snapshot ←
            driving
              domains
              ( do
                  -- The refused wait ended the tick's work and the instance, whose shutdown is held: the tick has
                  -- completed, and the failure has not yet settled.
                  awaitEntered fx "shutdown"
                  (held, revision) ← snapshotNow domains
                  (snapTick held, revision, evidenceOf held) `shouldBe` (0, 0, Nothing)
                  readTVarIO (sharedCommitted (domainsShared domains)) `shouldReturn` snapWorld held
                  releaseGate fx "shutdown"
              )
              >>= expectFailed
          snapTick snapshot `shouldBe` 0
          fmap (failKind . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "refused wait"
          awaitLine fx "shutdown failed"
          revisionNow domains `shouldReturn` 1

    it "is a scheduler-refused wait in the final segment, however the owner's thread and the driver's interleave: it is never committed" $
      forM_ [1 .. 10 ∷ Int] $ \_ →
        withSample (\config → withWait config {configGameplaySource = gameplayWith ["function update(self, dt) staging.move(0, 1, 0) staging.finish() sched.wait_ticks(0) end"]}) $ \_ _ domains → do
          snapshot ← stepTick domains >>= expectFailed
          snapTick snapshot `shouldBe` 0
          revisionNow domains `shouldReturn` 1

  describe "what a failure leaves for the stop" $
    it "has quiesced every surviving instance before it is published: a bystander's shutdown that raises is counted in the one snapshot, and the stop finds nothing left to tell" $
      withSample
        ( \config →
            config
              { configGameplaySource = gameplayWith ["function update(self, dt) error('behavior failed') end"]
              , configGameplayInstances = [bystander]
              , configGameplayModules = [extraModule ["function shutdown(self, reason) error('shutdown failed') end"]]
              }
        )
        $ \_ _ domains → do
          snapshot ← stepTick domains >>= expectFailed
          revisionNow domains `shouldReturn` 1
          -- The bystander was stopped before the failure was published, and its shutdown's error is the failure's
          -- later one: it is in the snapshot, not told of afterwards.
          fmap evidenceLater (evidenceOf snapshot) `shouldBe` Just 1
          _ ← stopSession domains
          revisionNow domains `shouldReturn` 1
          (latest, _) ← snapshotNow domains
          latest `shouldBe` snapshot
          evidence ← cleanupEvidence domains
          (evidenceFailures evidence, map failWho (evidenceAfter evidence)) `shouldBe` (2, [])
          held ← sessionFailures <$> readTVarIO (sharedSession (domainsShared domains))
          map failWho held `shouldBe` ["gameplay", "bystander"]
  describe "what else failed while the instance ended" $
    it "is the session's too, beside the primary and never in its place: an update that fails and a shutdown that fails" $
      withSample
        ( \config →
            config
              { configInput = []
              , configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end", "function shutdown(self, reason) error('shutdown failed') end"]
              }
        )
        $ \_ _ domains → do
          snapshot ← stepTick domains >>= expectFailed
          fmap (failStage . evidencePrimary) (evidenceOf snapshot) `shouldBe` Just "update"
          fmap evidenceLater (evidenceOf snapshot) `shouldBe` Just 1
          held ← sessionFailures <$> readTVarIO (sharedSession (domainsShared domains))
          map failStage held `shouldBe` ["update", "shutdown"]
          Text.unpack (failMessage (held !! 1)) `shouldSatisfy` ("shutdown failed" `isInfixOf`)

  describe "the publication that ends the session" $ do
    it "is the publisher's alone from the moment it is taken: a stop that comes while it is held waits for it, and the one failure snapshot is published" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains
          control
          (sampleConfig fx ui) {configInput = [], configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end"], configPublishHook = \point → when (point == AfterClaim) (holdAt fx "claimed")}
          $ \domains → withReleased fx ["claimed"] $ do
            -- A stop asked for while the publication is held waits for nothing and changes nothing: it must not retire the
            -- owners, and so close the publisher, under it. The finalization is the application thread's, after.
            outcome ← driving domains (awaitEntered fx "claimed" >> requestStop domains >> replicateM_ 2000 yield >> releaseGate fx "claimed")
            outcome `shouldSatisfy` \case TickFailed _ → True; _ → False
            _ ← stopSession domains
            (snapshot, revision) ← snapshotNow domains
            revision `shouldBe` 1
            snapStatus snapshot `shouldSatisfy` \case Failed _ → True; _ → False

    forM_ [("an instance's failure", Nothing), ("a task's fault", Just "function update(self, dt) staging.finish() end")] $ \(label, task) →
      it ("closes admission when " <> label <> " is recorded, before the driver has published it") $ do
        fx ← newFx
        ui ← newFakeUi
        probe ← newEmptyMVar
        answered ← newIORef Nothing
        let hook point = when (point == BeforeClaim) (join (readMVar probe))
            source = maybe ["function update(self, dt) error('update failed') end"] (\ok → [ok, "function task_fails() error('task failed') end"]) task
            entries = maybe [] (const [EntryPoint "task_fails" Required [] []]) task
        withBoundary $ \control →
          withDomains control (sampleConfig fx ui) {configInput = [], configGameplaySource = gameplayWith source, configGameplayEntries = entries, configPublishHook = hook} $ \domains → do
            -- The driver is told of the failure, and has not yet taken the publication: an offer now is answered closed.
            putMVar probe $ do
              answer ← offer domains 0
              atomicModifyIORef' answered (\held → (maybe (Just answer) Just held, ()))
            forM_ task $ \_ → admitGameplayTask domains (TaskRequest (ModuleRef "gameplay" "1") "task_fails" [] OrdinaryClass OneShot (Just "faulting task"))
            _ ← stepTick domains >>= expectFailed
            readIORef answered `shouldReturn` Just Closed

  describe "a session takes no task once it has failed or stopped" $ do
    let runs = gameplayWith ["function update(self, dt) staging.finish() end", "function task_runs() fx.record('task ran') end"]
        runsConfig config = config {configGameplaySource = runs, configGameplayEntries = [EntryPoint "task_runs" Required [] []]}
        taskRuns = TaskRequest (ModuleRef "gameplay" "1") "task_runs" [] OrdinaryClass OneShot (Just "late task")
    it "refuses a task after the failure was published, and the task never runs" $
      withSample (\config → (runsConfig config) {configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end", "function task_runs() fx.record('task ran') end"]}) $ \fx _ domains → do
        _ ← stepTick domains >>= expectFailed
        admitGameplayTask domains taskRuns >>= (`shouldSatisfy` \case TaskAdmissionClosed → True; _ → False)
        _ ← stopSession domains
        fxLines fx >>= (`shouldNotContain` ["task ran"])
    it "refuses a task after a stop, and the task never runs" $
      withSample runsConfig $ \fx _ domains → do
        _ ← stopSession domains
        admitGameplayTask domains taskRuns >>= (`shouldSatisfy` \case TaskAdmissionClosed → True; _ → False)
        fxLines fx >>= (`shouldNotContain` ["task ran"])
    it "refuses a task once the failure is recorded, before the driver has published it" $
      withSample (\config → (runsConfig config) {configGameplaySource = gameplayWith ["function update(self, dt) error('update failed') end", "function task_runs() fx.record('task ran') end"]}) $ \fx _ domains → do
        atomically (failSession (domainsShared domains) (SessionFailure "test" "run" "run" 0 "script fault" "recorded"))
        admitGameplayTask domains taskRuns >>= (`shouldSatisfy` \case TaskAdmissionClosed → True; _ → False)
        _ ← stopSession domains
        fxLines fx >>= (`shouldNotContain` ["task ran"])
    it "does not publish the ending while an admission that began before it is unfinished, and then publishes it" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains control (runsConfig (sampleConfig fx ui)) {configInput = [], configTaskHook = holdAt fx "admitting"} $ \domains →
          withReleased fx ["admitting"] $ do
            admit ← spawn (admitGameplayTask domains taskRuns)
            awaitEntered fx "admitting"
            _ ← alongside (waitFor (awaitClosed domains) >> replicateM_ 2000 yield >> (revisionNow domains `shouldReturn` 0) >> releaseGate fx "admitting") (stopSession domains)
            admit >>= (`shouldSatisfy` \case TaskAccepted _ _ → True; _ → False)
            (snapshot, revision) ← snapshotNow domains
            (revision, snapStatus snapshot) `shouldBe` (1, Stopped)

  describe "the tasks a session holds" $ do
    let task name entry = TaskRequest (ModuleRef "gameplay" "1") entry [] OrdinaryClass OneShot (Just name)
        entries = [EntryPoint "task_runs" Required [] [], EntryPoint "task_fails" Required [] [], EntryPoint "task_waits" Required [] [], EntryPoint "task_fails_late" Required [] [], EntryPoint "task_loops" Required [] []]
        taskFunctions =
          [ "function task_runs() fx.record('task ran') end"
          , "function task_fails() error('task failed') end"
          , "function task_waits() sched.wait_ticks(1000) end"
          , "function task_fails_late() fx.hold('task') error('task failed') end"
          , "function task_loops() while true do fx.record('loop') sched.wait_ticks(1) end end"
          ]
        source = gameplayWith ("function update(self, dt) staging.finish() end" : taskFunctions)
        tasksConfig config = withWait config {configGameplaySource = source, configGameplayEntries = entries}
        accepted = \case TaskAccepted _ _ → True; _ → False
        refusedFull = \case TaskQueueFull → True; _ → False
        held = boundSessionTasks defaultBounds
        failingWith = gameplayWith ("function update(self, dt) error('update failed') end" : taskFunctions)
    it "are no more than the session's bound, and a tick goes on while the owner holds that many that have not settled" $
      withSample tasksConfig $ \_ _ domains → do
        first ← forM [1 .. held] $ \_ → admitGameplayTask domains (task "waiting task" "task_waits")
        map accepted first `shouldBe` replicate held True
        admitGameplayTask domains (task "waiting task" "task_waits") >>= (`shouldSatisfy` refusedFull)
        -- Every task is suspended and holds its slot; the update has one of its own.
        stepTick domains >>= (`shouldSatisfy` \case TickCommitted _ → True; _ → False)
        admitGameplayTask domains (task "waiting task" "task_waits") >>= (`shouldSatisfy` refusedFull)
    it "are settled by a stop however many the owner holds: the stop waits for no slot" $
      withSample tasksConfig $ \_ _ domains → do
        forM_ [1 .. held] $ \_ → admitGameplayTask domains (task "task" "task_runs")
        stopBounded domains
        (snapshot, _) ← snapshotNow domains
        snapStatus snapshot `shouldBe` Stopped
        heldTasks domains `shouldReturn` 0
    it "are stopped, and settled, by a stop: a task that waits for ticks that will never be granted does not keep it waiting" $
      withSample tasksConfig $ \_ _ domains → do
        forM_ [1 .. held] $ \_ → admitGameplayTask domains (task "waiting task" "task_waits")
        stopBounded domains
        (snapshot, _) ← snapshotNow domains
        snapStatus snapshot `shouldBe` Stopped
        sessionFailureCount <$> readTVarIO (sharedSession (domainsShared domains)) >>= (`shouldBe` 0)
        heldTasks domains `shouldReturn` 0
    forM_ [1, 5, maxSessionTasks] $ \limit →
      it ("leaves the update a slot whatever the bound is: " <> show limit <> " suspended tasks leave a tick and a stop able to run") $
        withSample (\config → (tasksConfig config) {configBounds = (configBounds config) {boundSessionTasks = limit}}) $ \_ _ domains → do
          first ← forM [1 .. limit] $ \_ → admitGameplayTask domains (task "waiting task" "task_waits")
          map accepted first `shouldBe` replicate limit True
          admitGameplayTask domains (task "waiting task" "task_waits") >>= (`shouldSatisfy` refusedFull)
          stepTick domains >>= (`shouldSatisfy` \case TickCommitted _ → True; _ → False)
          stopBounded domains
          (snapshot, _) ← snapshotNow domains
          snapStatus snapshot `shouldBe` Stopped
    it "does not leave the stop waiting for ever when its first caller is cancelled while it waits for an admission: what was asked is tracked, and a second stop completes" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains control (tasksConfig (sampleConfig fx ui)) {configInput = [], configTaskHook = holdAt fx "admitting"} $ \domains →
          withReleased fx ["admitting"] $ do
            admit ← spawn (admitGameplayTask domains (task "task" "task_runs"))
            awaitEntered fx "admitting"
            -- The first stop is the application thread's own call, cancelled while it waits for the admission.
            first ← cancelWhen (waitFor (awaitClosed domains) >> replicateM_ 2000 yield) (stopSession domains)
            first `shouldSatisfy` isNothing
            releaseGate fx "admitting"
            admit >>= (`shouldSatisfy` accepted)
            stopBounded domains
            (snapshot, _) ← snapshotNow domains
            snapStatus snapshot `shouldBe` Stopped
    it "quiesces what a session admitted before it publishes a failure: a task that goes on running after it yields is stopped, and the owner stays alive" $
      withSample (\config → (tasksConfig config) {configGameplaySource = failingWith}) $ \fx _ domains → do
        _ ← admitGameplayTask domains (task "looping task" "task_loops")
        _ ← stepTick domains >>= expectFailed
        heldTasks domains `shouldReturn` 0
        -- Nothing the task does is recorded once the failure is published.
        loopsThen ← length . filter (== "loop") <$> fxLines fx
        replicateM_ 2000 yield
        loopsNow ← length . filter (== "loop") <$> fxLines fx
        loopsNow `shouldBe` loopsThen
        atomically (scheduledStatus (gameplayOwner domains)) >>= (`shouldSatisfy` isLive)
    it "quiesces a task whose admission overlapped the failure: the failure is published after the task is stopped" $ do
      fx ← newFx
      ui ← newFakeUi
      withBoundary $ \control →
        withDomains control (tasksConfig (sampleConfig fx ui)) {configInput = [], configGameplaySource = failingWith, configTaskHook = holdAt fx "admitting"} $ \domains →
          withReleased fx ["admitting"] $ do
            admit ← spawn (admitGameplayTask domains (task "looping task" "task_loops"))
            awaitEntered fx "admitting"
            _ ← driving domains (waitFor (awaitClosed domains) >> releaseGate fx "admitting" >> (admit >>= (`shouldSatisfy` accepted))) >>= expectFailed
            heldTasks domains `shouldReturn` 0
    it "is told of the fault of a task that is running when the stop is asked for: the stop decides the status after it, and the failure is the task's" $ do
      fx ← newFx
      ui ← newFakeUi
      reached ← newIORef False
      let hook point = when (point == BeforeClaim) (writeIORef reached True)
      withBoundary $ \control →
        withDomains control (tasksConfig (sampleConfig fx ui)) {configInput = [], configPublishHook = hook} $ \domains →
          withReleased fx ["task"] $ do
            admitGameplayTask domains (task "faulting task" "task_fails_late") >>= (`shouldSatisfy` accepted)
            -- The task is running, held in its segment, which a stop does not preempt: it is asked to stop, and goes on to
            -- fault. The stop waits for its settlement and has not come to its publication.
            awaitEntered fx "task"
            _ ←
              alongside
                ( do
                    waitFor (awaitClosed domains)
                    replicateM_ 2000 yield
                    readIORef reached `shouldReturn` False
                    releaseGate fx "task"
                )
                (stopSession domains)
            (snapshot, _) ← snapshotNow domains
            fmap (failWho . evidencePrimary) (failedEvidence snapshot) `shouldBe` Just "faulting task"

  describe "the settlements of the tasks a session watches are consumed once" $
    it "counts each task's fault once however many stops overlap" $
      forM_ [1 .. 20 ∷ Int] $ \_ → do
        let tasks = 3 ∷ Int
        withSample
          ( \config →
              config
                { configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end", "function task_fails() error('task failed') end"]
                , configGameplayEntries = [EntryPoint "task_fails" Required [] []]
                }
          )
          $ \_ _ domains → do
            -- The first fault is told as soon as it has one, which closes admission: the tasks after it may be refused.
            admissions ← forM [1 .. tasks] $ \_ →
              admitGameplayTask domains (TaskRequest (ModuleRef "gameplay" "1") "task_fails" [] OrdinaryClass OneShot (Just "faulting task"))
            let tickets = [ticket | TaskAccepted _ ticket ← admissions]
            tickets `shouldSatisfy` (not . null)
            settled ← forM tickets (generous . awaitTask (domainsControl domains))
            -- The first fault asks the tasks that have not run to stop, so how many fault is the library's to say; each is
            -- told once, by its watcher, the driver and the stop however they overlap.
            let faulted = length [() | one ← settled, SettledFaulted _ ← [settledOutcome one]]
            _ ← stepTick domains
            _ ← stopSession domains
            faulted `shouldSatisfy` (>= 1)
            sessionFailureCount <$> readTVarIO (sharedSession (domainsShared domains)) >>= (`shouldBe` faulted)
  describe "a task's settlement is told once, whoever learns it" $
    it "records the fault once however many times it is told: the watcher, and this thread telling it again" $
      withSample
        ( \config →
            config
              { configGameplaySource = gameplayWith ["function update(self, dt) staging.finish() end", "function task_fails() error('task failed') end"]
              , configGameplayEntries = [EntryPoint "task_fails" Required [] []]
              }
        )
        $ \_ _ domains → do
          ticket ← admitGameplayTask domains (TaskRequest (ModuleRef "gameplay" "1") "task_fails" [] OrdinaryClass OneShot (Just "faulting task")) >>= \case
            TaskAccepted _ ticket → pure ticket
            other → throwIO (userError ("the task was not admitted: " <> show other))
          settlement ← generous (awaitTask (domainsControl domains) ticket)
          stopped ← newTVarIO False
          -- The task is the session's first: its place among them is nought, which is all telling it looks at.
          let again = Watched "faulting task" ticket 0 stopped
          replicateM_ 3 (tellTask domains again settlement)
          waitFor (readTVar (sharedSession (domainsShared domains)) >>= \state → when (sessionFailureCount state < 1) retry)
          heldTasks domains `shouldReturn` 0
          sessionFailureCount <$> readTVarIO (sharedSession (domainsShared domains)) >>= (`shouldBe` 1)
  where
    isHalted = \case
      TickHalted → True
      _ → False
    isLive = \case
      WorkerLive → True
      _ → False
