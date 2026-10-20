-- | The failure of the gameplay session (#499 requirements 1 to 4): any failure of script execution on the gameplay
-- owner fails the session; the session is then quiescent, with the last good world and committed tick; the failure is
-- published once beside them; and the driver learns of a failure in tick T before it decides T's commit, on every
-- ordering the examples can force with gates.
module Test.Domains.Failure (spec) where

import Control.Concurrent.STM (atomically, readTVarIO)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing)
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerLive))
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsGameplay, domainsShared)
  , DomainsConfig (configExtensions, configGameplayEntries, configGameplayInstances, configGameplayModules, configGameplaySource)
  , Evidence (evidenceAfter, evidenceFailures, evidenceGameplay)
  , Extension (Extension)
  , GameSnapshot (snapStatus, snapTick, snapWorld)
  , OwnerEvidence (evidenceEnded)
  , SessionStatus (Failed)
  , Started (startedOwner)
  , TickOutcome (TickFailed, TickHalted)
  , Where (InGameplay)
  , admitGameplayTask
  , cleanupEvidence
  , defaultBounds
  , stepTick
  , stopSession
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Scripts (moduleSource)
import Hetoimasia.Sample.LuaDomains.Session (SessionState (sessionFailureCount, sessionFailures))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCommitted, sharedSession, sharedTick))
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure (..))
import Hetoimasia.Sample.LuaDomains.World (initialWorld)
import Hetoimasia.Scripting.Lua.Instance (InstanceKind (EventOnly, RunOnce), InstanceRequest (..))
import Hetoimasia.Scripting.Lua.Owner (EntryPoint (EntryPoint), ModuleRef (ModuleRef), ModuleSource, Requirement (Required))
import Hetoimasia.Scripting.Lua.Registration (WaitKind (WaitLogical), namespace, stateOperation, waitOperation)
import Hetoimasia.Scripting.Lua.Scheduled
  ( ScheduledOwner
  , ServiceClass (OrdinaryClass)
  , TaskAdmission (TaskAccepted)
  , TaskKind (OneShot)
  , TaskRequest (..)
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
          snapshot ← awaitRevision domains 1
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

    it "is two failures in one tick: the first is the session's, the second is counted beside it" $
      withSample
        ( \config →
            config
              { configGameplaySource = gameplayWith ["function update(self, dt) fx.hold('both') error('behavior failed') end", "function task_fails() error('task failed') end"]
              , configGameplayEntries = [EntryPoint "task_fails" Required [] []]
              }
        )
        $ \fx _ domains → withReleased fx ["both"] $ do
          collect ← spawn (stepTick domains)
          awaitEntered fx "both"
          _ ← admitGameplayTask domains (TaskRequest (ModuleRef "gameplay" "1") "task_fails" [] OrdinaryClass OneShot (Just "faulting task"))
          releaseGate fx "both"
          snapshot ← collect >>= expectFailed
          -- Both are the session's; whichever the driver was told of first is primary, and the other is counted.
          fmap evidenceLater (evidenceOf snapshot) `shouldBe` Just 1
          held ← sessionFailures <$> readTVarIO (sharedSession (domainsShared domains))
          sort (map failWho held) `shouldBe` ["faulting task", "gameplay"]
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
          collect ← spawn (stepTick domains)
          -- The refused wait ended the tick's work and the instance, whose shutdown is held: the tick has
          -- completed, and the failure has not yet settled.
          awaitEntered fx "shutdown"
          (held, revision) ← snapshotNow domains
          (snapTick held, revision, evidenceOf held) `shouldBe` (0, 0, Nothing)
          readTVarIO (sharedCommitted (domainsShared domains)) `shouldReturn` snapWorld held
          releaseGate fx "shutdown"
          snapshot ← collect >>= expectFailed
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
    it "counts a failure told of after the failure was published, keeps the first as the session's, and publishes nothing more" $
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
          -- The bystander's shutdown raises when the session is stopped, after the failure was published.
          _ ← stopSession domains
          revisionNow domains `shouldReturn` 1
          (latest, _) ← snapshotNow domains
          latest `shouldBe` snapshot
          evidence ← cleanupEvidence domains
          (evidenceFailures evidence, map failWho (evidenceAfter evidence)) `shouldBe` (2, ["bystander"])
  where
    isHalted = \case
      TickHalted → True
      _ → False
    isLive = \case
      WorkerLive → True
      _ → False
