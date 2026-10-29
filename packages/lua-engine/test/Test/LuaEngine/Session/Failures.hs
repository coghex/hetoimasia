{-# LANGUAGE OverloadedStrings #-}

-- | The failure policy after the roots started: which failure ends which part of the session, what stays
-- running, and what a status read and the outcome say while it happens.
--
-- The failures are the real ones: a script that raises, a required request nothing ever polls, a provider
-- whose reader fails, a sink that raises, a cleanup that fails when the owner retires. The ones that end an
-- owner as a failure of the host are raised by supervision at its boundary as well, so those examples run
-- under 'fatalSetup' and assert the session's own account inside the body.
module Test.LuaEngine.Session.Failures (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Data.IORef (newIORef, readIORef, writeIORef)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..))
import Control.Concurrent (forkIO, myThreadId, throwTo)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, displayException, fromException, throwIO, toException, try, tryWithContext)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure)
import Control.Monad (forM_, void, when)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Data.List (isInfixOf)
import Hetoimasia.Foundation.Log (LogEntry (entryMessage), Logger, callbackSink, defaultLogFilter, mkLogger, unsafeComponent)
import Hetoimasia.Foundation.Worker (awaitCompletion, workerDefinition)
import Hetoimasia.Runtime.Supervision (Disposition (Required), Recognition (Unrecognized), Role (Service), SupervisedStart (WorkerStarted), WorkerPolicy (..), startSupervised, supervisedWorker)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, injectedDefect, openGate)
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "failures" $ do
  logicalFailure
  otherFailures
  accountingHeld
  hostFailures
  notFailures
  releases
  outcomes

linesWith ∷ Text → World → IO [Text]
linesWith prefix world = filter (prefix `Text.isPrefixOf`) <$> outLines world

grantsIssued ∷ Recorder → IO [Word64]
grantsIssued recorder = (\points → [number | GrantIssued number ← points]) <$> recorded recorder

-- | The behavior whose logical update prints its tick and raises at the tick given, and whose presentation
-- update prints a line.
failingAt ∷ Int → Script
failingAt tick =
  printScript
    { scInit = []
    , scUpdate =
        [ "if api.role == 'gameplay' then"
        , "  local t = api.time.tick()"
        , "  print('tick ' .. t)"
        , "  if t == " <> Text.pack (show tick) <> " then error('boom at ' .. t) end"
        , "else"
        , "  print('ui update')"
        , "end"
        ]
    }

-- Beside a healthy presentation role ----------------------------------------------------------------------------------------

logicalFailure ∷ Spec
logicalFailure = describe "of the logical role after the start" $ do
  it "stops the logical role alone, with its first failure published and a healthy presentation role still running, and no later tick" $
    withSetup (setup (roleScript (failingAt 2))) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 2000000 (elem "tick 2" <$> outLines world)
        -- the failure is latched, and published, whatever the retirement has reached
        status ← awaitStatus session (maybe False roleFailed . gameplayOf)
        statusStopping status `shouldBe` False
        fmap roleFailed (presentationOf status) `shouldBe` Just False
        case gameplayOf status >>= roleFailure of
          Nothing → expectationFailure "the failure was not published"
          Just found → do
            rfCode found `shouldBe` LuaError
            rfStage found `shouldBe` OnUpdate
            rfRole found `shouldBe` Gameplay
            rfInstance found `shouldBe` Just "inst-1"
            rfContent found `shouldBe` Just "modules-test"
            rfMessage found `shouldSatisfy` Text.isInfixOf "boom at 2"
            rfTraceback found `shouldSatisfy` (/= Nothing)
        -- a failed role never goes back to ready or running
        awaitPhase session Gameplay Retired
        retired ← statusNow session
        fmap rolePhase (gameplayOf retired) `shouldBe` Just Retired
        fmap roleFailed (gameplayOf retired) `shouldBe` Just True
        -- the presentation role goes on with its own services, and the logical role is granted nothing more
        advanceClock world 5000000
        passTime world 1000000000 (elem "ui update" <$> outLines world)
        -- the probe is told after the grant commits, and what the tick did can be seen before that: wait for it
        awaitPoint recorder (GrantIssued 2)
        grants ← grantsIssued recorder
        grants `shouldBe` [1, 2]
        ticks ← linesWith "tick" world
        ticks `shouldBe` ["tick 1", "tick 2"]
        requestStop session StopQuit
      out ← outLines world
      out `shouldSatisfy` elem "shutdown gameplay failed"
      out `shouldSatisfy` elem "shutdown presentation stopped"
      -- an eventual stop cannot erase an earlier failure
      outVerdict outcome `shouldBe` VerdictFailure
      outQuit outcome `shouldBe` True
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]

  it "latches a required request's failure at its assigned tick although Lua never polled it, and runs none of the instance's ordinary work" $
    withSetup
      (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then self.request = api.content.data('lua/missing.bin') end"], scUpdate = ["print('update ' .. api.role)"]}))
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitRegistration world 1000
          nudge world 1000000
          status ← awaitStatus session (maybe False roleFailed . gameplayOf)
          fmap rolePhase (presentationOf status) `shouldBe` Just Running
          statusStopping status `shouldBe` False
          requestStop session StopQuit
        out ← outLines world
        out `shouldNotSatisfy` elem "update gameplay"
        case outFailures outcome of
          [found] → do
            rfCode found `shouldBe` RequiredRequest
            rfStage found `shouldBe` OnRequest
            rfRole found `shouldBe` Gameplay
            rfInstance found `shouldBe` Just "inst-1"
          other → expectationFailure ("expected one failure, found " <> show other)

  it "publishes the failure while a provider's retirement still holds the role, and reports the role retired only when it has retired" $
    withSetup
      ( addFile
          ("lua/slow.bin", "slow")
          (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then self.request = api.content.data('lua/slow.bin', {tick_offset = 5}) end"], scUpdate = ["if api.role == 'gameplay' then error('boom') end"]}))
      )
      $ \env → do
        let world = seWorld env
            probe = ssProbeOf env
        closeGate probe "lua/slow.bin"
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitReadOf env "lua/slow.bin"
          awaitRegistration world 1000
          nudge world 1000000
          status ← awaitStatus session (maybe False roleFailed . gameplayOf)
          -- the failure is visible, the role is stopping and not retired: its provider has not retired what it holds
          fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
          fmap rolePhase (presentationOf status) `shouldBe` Just Running
          openGate probe "lua/slow.bin"
          awaitPhase session Gameplay Retired
          status' ← statusNow session
          fmap roleFailed (gameplayOf status') `shouldBe` Just True
          requestStop session StopQuit

-- | What the proof about a held retirement observed.
data HeldRetirement = HeldRetirement
  { hrGrants ∷ ![Word64]
  -- ^ The ticks granted, while the retirement was held.
  , hrUpdates ∷ !Int
  -- ^ How many times the presentation role updated while it was held.
  , hrPublished ∷ !Bool
  -- ^ Whether the presentation role's history was published after it was stopped, without opening the gate.
  , hrRetired ∷ !Bool
  -- ^ Whether the presentation role was retired, without opening the gate.
  , hrStops ∷ ![Test.LuaEngine.Session.Support.Role]
  -- ^ The owners that had been handed their stop, without opening the gate.
  , hrLogicalRetired ∷ !Bool
  -- ^ Whether the logical role was retired, without opening the gate.
  }
  deriving (Eq, Show)

-- | A logical tick finishes whose instance ending owes a provider's retirement, held at a test gate: the first
-- instance of the logical role fails, the role's policy ends its second instance too, and that one holds a read the pool
-- has not returned, which its shutdown and so the tick's accounting wait for. While the gate is held the presentation
-- role keeps updating and is stopped; what was observed before the gate is opened.
heldRetirement ∷ [Protection] → IO HeldRetirement
heldRetirement removedProtections =
  withSetup
    ( addFile
        ("lua/slow.bin", "slow")
        ( (setup
            ( roleScript
                printScript
                  { scInit = ["if api.role == 'gameplay' and api.instance_id == 'inst-2' then self.request = api.content.data('lua/slow.bin', {tick_offset = 50}) end"]
                  , scUpdate = ["if api.role == 'gameplay' and api.instance_id == 'inst-1' then error('boom') end", "if api.role == 'presentation' then print('ui update') end"]
                  , scShutdown = ["print('shutdown ' .. api.role .. ' ' .. reason)"]
                  }
            )
          )
            { suHarness = noHarness {harnessSecond = [Gameplay]}
            }
        )
    )
    $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      closeGate probe "lua/slow.bin"
      recorder ← newRecorder
      handles ← newTVarIO Map.empty
      observed ← newIORef (HeldRetirement [] 0 False False [] False)
      let harness = (recordingHarness recorder noHarness) {harnessRemoved = removedProtections, harnessSecond = [Gameplay], harnessOwner = \role found → atomically (modifyTVar' handles (Map.insert role found))}
          countUpdates = length . filter (== "ui update") <$> outLines world
      _ ← runCaught env harness $ \_ session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitReadOf env "lua/slow.bin"
        awaitRegistration world 1000
        -- the first tick: the first instance fails, and the second, which holds the read, is ended with it
        nudge world 1000000
        void (awaitStatus session (maybe False roleFailed . gameplayOf))
        -- the probe is told after the grant commits, and the owner's failure can be seen before that: wait for it
        awaitPoint recorder (GrantIssued 1)
        -- the tick has finished and its accounting is awaited (in the control, by the driver by itself)
        if null removedProtections then pure () else awaitPoint recorder AccountingWait
        -- the presentation role goes on updating
        seenBefore ← countUpdates
        passTime world 1000000000 ((> seenBefore) <$> countUpdates)
        updates ← countUpdates
        requestStop session StopQuit
        found ← readTVarIO handles
        if null removedProtections
          then awaitPhase session Presentation Retired
          else forM_ (Map.lookup Presentation found) ownerSettled
        history ← historyNow session
        status ← statusNow session
        points ← recorded recorder
        writeIORef
          observed
          HeldRetirement
            { hrGrants = [number | GrantIssued number ← points]
            , hrUpdates = updates - seenBefore
            , hrPublished = any ((== Presentation) . ikRole) (Map.keys (historyFacts history))
            , hrRetired = fmap rolePhase (presentationOf status) == Just Retired
            , hrStops = historyStopped history
            , hrLogicalRetired = fmap rolePhase (gameplayOf status) == Just Retired
            }
        openGate probe "lua/slow.bin"
        void (awaitRetired session)
      readIORef observed

-- | The driver is cancelled while it watches the accounting of a finished tick that a provider's retirement holds: the
-- session unwinds through the watch (cleared on the way out), keeps the cancellation, and retires every role once the
-- retirement completes.
cancelledWhileWatched ∷ IO (Either Caught SessionOutcome, Bool)
cancelledWhileWatched =
  withSetup
    ( addFile
        ("lua/slow.bin", "slow")
        ( (setup
            ( roleScript
                printScript
                  { scInit = ["if api.role == 'gameplay' and api.instance_id == 'inst-2' then self.request = api.content.data('lua/slow.bin', {tick_offset = 50}) end"]
                  , scUpdate = ["if api.role == 'gameplay' and api.instance_id == 'inst-1' then error('boom') end"]
                  , scShutdown = ["print('shutdown ' .. api.role .. ' ' .. reason)"]
                  }
            )
          )
            { suHarness = noHarness {harnessSecond = [Gameplay]}
            }
        )
    )
    $ \env → do
      let world = seWorld env
          probe = ssProbeOf env
      closeGate probe "lua/slow.bin"
      recorder ← newRecorder
      (ended, session) ← runCaught env ((recordingHarness recorder noHarness) {harnessSecond = [Gameplay]}) $ \driver session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitReadOf env "lua/slow.bin"
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitStatus session (maybe False roleFailed . gameplayOf))
        -- the finished tick's accounting is watched and held by the retirement
        throwTo driver ThreadKilled
        void (awaitStatus session statusStopping)
        openGate probe "lua/slow.bin"
        void (awaitRetired session)
      found ← outcomeNow session
      pure (ended, outRetired found)

accountingHeld ∷ Spec
accountingHeld = describe "a provider's retirement held after a logical tick has finished" $ do
  it "unwinds a cancellation of the driver through the watched accounting, retiring every role once the retirement completes" $ do
    (ended, retired) ← cancelledWhileWatched
    raisedKilled ended `shouldBe` True
    retired `shouldBe` True

  it "grants no further tick, keeps the presentation role updating, and stops every owner and publishes and retires the presentation role without the gate opened, leaving the logical role unretired" $ do
    found ← heldRetirement []
    hrGrants found `shouldBe` [1]
    hrUpdates found `shouldSatisfy` (>= 1)
    hrPublished found `shouldBe` True
    hrRetired found `shouldBe` True
    hrStops found `shouldBe` [Gameplay, Presentation]
    hrLogicalRetired found `shouldBe` False

  describe "with the driver waiting for the accounting by itself (a negative control)" $
    it "leaves the presentation role unpublished and unretired while the retirement is held, which the proof above detects" $ do
      found ← heldRetirement [ProtectAccountingEvent]
      hrPublished found `shouldBe` False
      hrRetired found `shouldBe` False

-- The rest of the session ---------------------------------------------------------------------------------------------------------

otherFailures ∷ Spec
otherFailures = describe "that end the whole session" $ do
  it "ends the session when the presentation role fails, stopping the logical role in order" $
    withSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'presentation' then error('ui boom') end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        nudgeArmed world 1000000 1000000000
        status ← awaitStatus session (maybe False roleFailed . presentationOf)
        statusStopping status `shouldBe` True
        fmap roleFailed (gameplayOf status) `shouldBe` Just False
        void (awaitRetired session)
      out ← outLines world
      out `shouldSatisfy` elem "shutdown gameplay stopped"
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfRole (outFailures outcome) `shouldBe` [Presentation]

  it "ends the session when a one-role session's only role fails" $ do
    withSetup ((setup (roleScript (failingAt 1))) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]
      outRetired outcome `shouldBe` True
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error('ui boom')"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Presentation Running
        nudgeArmed world 1000000 1000000000
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfRole (outFailures outcome) `shouldBe` [Presentation]

  it "ends the session on the terminal failure the unavailable-state guard latches, once, and not as a role's failure" $
    withSetup (setup (roleScript printScript)) $ \env → do
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        first ← latchTerminalFailure session (newRoleFailure StateUnavailable OnUpdate Presentation "state is unavailable")
        second ← latchTerminalFailure session (newRoleFailure StateUnavailable OnUpdate Gameplay "state is unavailable")
        (first, second) `shouldBe` (True, False)
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outFailures outcome `shouldBe` []
      fmap rfRole (outTerminal outcome) `shouldBe` Just Presentation

  -- The terminal failure comes in by the public endpoint, built by whoever calls it: every text of it is counted in the
  -- bound of the record that is published, one example for each field, and one for all of them at once.
  mapM_
    ( \(name, oversize, bytesIn, ownBound) →
        it ("publishes a terminal failure whose " <> name <> " the caller built far beyond its bound within the record's bound") $
          withSetup (setup (roleScript printScript)) $ \env → do
            outcome ← runScenario env $ \session → do
              awaitPhase session Gameplay Running
              awaitPhase session Presentation Running
              void (latchTerminalFailure session (oversize (Text.replicate 20000 "x") (newRoleFailure StateUnavailable OnUpdate Presentation "state is unavailable")))
              void (awaitRetired session)
            case outTerminal outcome of
              Nothing → expectationFailure "the terminal failure was not published"
              Just found → do
                recordBytes found `shouldSatisfy` (<= limitRecord published)
                bytesIn found `shouldSatisfy` (<= ownBound published)
                bytesIn found `shouldSatisfy` (> 0)
            -- and the engine report, which carries the message, stays within the record's bound as well
            maybe 0 (utf8Bytes . eeMessage) (erPrimary (outEngine outcome)) `shouldSatisfy` (<= limitRecord published)
    )
    [ ("message", \text failure → failure {rfMessage = text}, utf8Bytes . rfMessage, limitMessage)
    , ("content identifier", \text failure → failure {rfContent = Just text}, maybe 0 utf8Bytes . rfContent, limitContent)
    , ("instance identity", \text failure → failure {rfInstance = Just text}, maybe 0 utf8Bytes . rfInstance, limitInstance)
    , ("path", \text failure → failure {rfPath = Just text}, maybe 0 utf8Bytes . rfPath, limitPath)
    , ("traceback", \text failure → failure {rfTraceback = Just text}, maybe 0 utf8Bytes . rfTraceback, limitTraceback)
    ]

  it "publishes a terminal failure whose every text is beyond its bound within the record's bound" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let huge = Text.replicate 20000 "x"
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        void
          ( latchTerminalFailure
              session
              (newRoleFailure StateUnavailable OnUpdate Presentation huge)
                { rfContent = Just huge
                , rfInstance = Just huge
                , rfPath = Just huge
                , rfTraceback = Just huge
                }
          )
        void (awaitRetired session)
      fmap recordBytes (outTerminal outcome) `shouldSatisfy` maybe False (<= limitRecord published)

-- Failures of the host --------------------------------------------------------------------------------------------------------------

hostFailures ∷ Spec
hostFailures = describe "of the host" $ do
  it "ends the whole session when a provider fails, leaving the failed owner's Lua unentered and the other role stopped in order" $ do
    let entry = roleScript printScript {scInit = ["if api.role == 'gameplay' then self.request = api.content.data('lua/boom.bin') end"], scUpdate = []}
    failure ←
      fatalSetup
        (addFile ("lua/boom.bin", "x") (setup entry)) {suReader = injectedDefect ["lua/boom.bin"] (userError "the pool's reader failed")}
        $ \env → do
          let world = seWorld env
              probe = ssProbeOf env
          -- the faulty read is held at the pool's gate until both roles are running, so that it cannot fail the session first
          closeGate probe "lua/boom.bin"
          outcome ← runScenario env $ \session → do
            awaitPhase session Gameplay Running
            awaitPhase session Presentation Running
            awaitReadOf env "lua/boom.bin"
            openGate probe "lua/boom.bin"
            void (awaitRetired session)
          out ← outLines world
          out `shouldSatisfy` elem "shutdown presentation stopped"
          out `shouldSatisfy` (not . any ("shutdown gameplay" `Text.isPrefixOf`))
          outVerdict outcome `shouldBe` VerdictFailure
          fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
          fmap eeRole (erPrimary (outEngine outcome)) `shouldBe` Just (Just Gameplay)
          fmap rfCode (outFailures outcome) `shouldBe` [HostFailure]
    Text.pack (displayException failure) `shouldSatisfy` Text.isInfixOf "ProviderDefect"

  it "ends the whole session when the authored output fails" $ do
    _ ←
      fatalSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'presentation' then print('ui update') end"]})) $ \env → do
        let world = seWorld env
        failSinkOn world "ui update"
        outcome ← runScenario env $ \session → do
          awaitPhase session Presentation Running
          nudgeArmed world 1000000 1000000000
          void (awaitRetired session)
        -- the output failed: nothing more is written through it, the stopped role's shutdown line included
        out ← outLines world
        out `shouldSatisfy` notElem "shutdown gameplay stopped"
        outVerdict outcome `shouldBe` VerdictFailure
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
        fmap eeRole (erPrimary (outEngine outcome)) `shouldBe` Just (Just Presentation)
    pure ()

  it "ends the session, stopping both roles, when another worker on the same supervision fails while they run" $ do
    gate ← newEmptyMVar
    _ ←
      fatalSetup (setup (roleScript printScript {scUpdate = []})) $ \env → do
        let world = seWorld env
        started ←
          startSupervised
            (seControl env)
            (WorkerPolicy Service Required (unsafeComponent "test.session.foreign") (\_ → pure Unrecognized))
            (workerDefinition "foreign" (\_ → pure ()) (\_ () → takeMVar gate >> throwIO (userError "the foreign worker failed")))
        case started of
          WorkerStarted _ → pure ()
          _ → throwIO (userError "the foreign worker did not start")
        outcome ← runScenario env $ \session → do
          awaitPhase session Presentation Running
          awaitPhase session Gameplay Running
          putMVar gate ()
          void (awaitRetired session)
        out ← outLines world
        out `shouldSatisfy` elem "shutdown presentation stopped"
        out `shouldSatisfy` elem "shutdown gameplay stopped"
        outVerdict outcome `shouldBe` VerdictFailure
        outRetired outcome `shouldBe` True
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
        fmap eeRole (erPrimary (outEngine outcome)) `shouldBe` Just Nothing
        fmap (Text.isInfixOf "the foreign worker failed" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True
    pure ()

  it "accounts the other workers' failures a delivery carries, each by its own worker, beside a failing owner of the session that supervision committed in the same batch" $ do
    gates ← mapM (const newEmptyMVar) [1 ∷ Int, 2]
    _ ←
      fatalSetup (setup (roleScript printScript {scUpdate = []})) $ \env → do
        let world = seWorld env
            foreignWorker (label, gate) = do
              started ←
                startSupervised
                  (seControl env)
                  (WorkerPolicy Service Required (unsafeComponent "test.session.foreign") (\_ → pure Unrecognized))
                  (workerDefinition label (\_ → pure ()) (\_ () → takeMVar gate >> throwIO (userError (Text.unpack label <> " failed"))))
              case started of
                WorkerStarted worker → pure worker
                _ → throwIO (userError "a foreign worker did not start")
        -- both foreign workers are registered before the session's owners, so the first of them is the batch's primary
        foreignWorkers ← mapM foreignWorker (zip ["the first foreign worker", "the second foreign worker"] gates)
        handles ← newTVarIO Map.empty
        recorder ← newRecorder
        holdAt recorder (Committed "AdmissionComplete")
        let harness = (recordingHarness recorder noHarness) {harnessOwner = \role found → atomically (modifyTVar' handles (Map.insert role found))}
        (_, session) ← runCaught env harness $ \_ session → do
          -- the driver is parked, so supervision handles nothing: let all three outcomes be published, then let it go
          awaitPoint recorder (Committed "AdmissionComplete")
          mapM_ (\gate → putMVar gate ()) gates
          found ← readTVarIO handles
          maybe (expectationFailure "no owner was told") (\owner → ownerCancel owner >> ownerSettled owner) (Map.lookup Gameplay found)
          mapM_ (atomically . void . awaitCompletion . supervisedWorker) foreignWorkers
          releaseHold recorder (Committed "AdmissionComplete")
          void (awaitRetired session)
        outcome ← outcomeNow session
        outVerdict outcome `shouldBe` VerdictFailure
        -- the primary the delivery carried, the second foreign failure it retained, and the owner's own cancellation
        mapM_
          (\wanted → length [() | message ← outcomeMessages outcome, Text.isInfixOf wanted message] `shouldBe` 1)
          ["the first foreign worker failed", "the second foreign worker failed", "cancelled"]
        outRetired outcome `shouldBe` True
        out ← outLines world
        length [line | line ← out, "shutdown" `Text.isPrefixOf` line] `shouldSatisfy` (<= 2)
    pure ()

  it "keeps the success of an init the driver was not looking at when its instance went on to fail" $
    withSetup ((setup (roleScript printScript {scUpdate = ["error('the first refresh fails')"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Resumed (InstanceKey Presentation 0))
      outcome ← runScenarioWith env (recordingHarness recorder noHarness) $ \session → do
        awaitPoint recorder (Resumed (InstanceKey Presentation 0))
        -- the init succeeds and the first refresh fails while the driver, which released the instance, is not looking
        pumpUntil world (elem "init presentation" <$> outLines world)
        awaitRegistration world 1000000
        passTime world 1000000000 (maybe False roleFailed . presentationOf <$> statusNow session)
        releaseHold recorder (Resumed (InstanceKey Presentation 0))
        void (awaitRetired session)
        status ← statusNow session
        fmap roleInitialized (presentationOf status) `shouldBe` Just True
        fmap rolePhase (presentationOf status) `shouldBe` Just Retired
      outVerdict outcome `shouldBe` VerdictFailure
      fmap rfStage (outFailures outcome) `shouldBe` [OnUpdate]

  it "accounts the owner's retained cleanup once when the driver itself fails, with the driver's failure first" $ do
    _ ←
      fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        failAt recorder (GrantIntent 2) (toException (userError "the driver failed"))
        (ended, session) ← runCaught env (recordingHarness recorder noHarness) $ \_ session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          passTime world 1000000 (elem "suspended" <$> outLines world)
          -- the second tick falls due: the driver raises at the grant, with a coroutine suspended in a failing close
          nudgeArmed world 1000 1000000
          void (awaitStatus session statusStopping)
        -- what the driver raised is what the call raises, with the owner's retained cleanup beside it, once
        raisedMessage ended `shouldSatisfy` Text.isInfixOf "the driver failed"
        outcome ← outcomeNow session
        outVerdict outcome `shouldBe` VerdictFailure
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
        fmap (Text.isInfixOf "the driver failed" . eeMessage) (erPrimary (outEngine outcome)) `shouldBe` Just True
        length [found | found ← erSecondary (outEngine outcome), eeCode found == CleanupFailure, Text.isInfixOf "close failed" (eeMessage found)] `shouldBe` 1
    pure ()

  it "carries the owner's retained cleanup beside a cancellation of the calling thread" $ do
    _ ←
      fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
        let world = seWorld env
        recorder ← newRecorder
        holdAt recorder (GrantIntent 2)
        self ← myThreadId
        handle ← newEmptyMVar
        _ ← forkIO $ do
          session ← readMVar handle
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          passTime world 1000000 (elem "suspended" <$> outLines world)
          nudgeArmed world 1000 1000000
          awaitPoint recorder (GrantIntent 2)
          throwTo self ThreadKilled
          void (awaitStatus session statusStopping)
          releaseHold recorder (GrantIntent 2)
        result ← tryWithContext @SomeException (runSession (scenarioSpec env (recordingHarness recorder noHarness)) (putMVar handle))
        case result of
          Left (ExceptionWithContext attached raised) → do
            fromException raised `shouldBe` Just ThreadKilled
            map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any ("close failed" `isInfixOf`)
          Right _ → expectationFailure "the cancellation was lost"
    pure ()

  mapM_
    ( \message →
        it ("finishes every teardown step when a cancellation lands and the diagnostic sink raises for \"" <> Text.unpack message <> "\"") $ do
          _ ←
            fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
              let world = seWorld env
              armed ← newTVarIO False
              let env' = env {seSpec = (seSpec env) {sxLogger = throwingLogger armed message}}
              recorder ← newRecorder
              holdAt recorder (GrantIntent 2)
              self ← myThreadId
              handle ← newEmptyMVar
              _ ← forkIO $ do
                session ← readMVar handle
                awaitPhase session Gameplay Running
                awaitRegistration world 1000
                passTime world 1000000 (elem "suspended" <$> outLines world)
                nudgeArmed world 1000 1000000
                awaitPoint recorder (GrantIntent 2)
                atomically (writeTVar armed True)
                throwTo self ThreadKilled
                void (awaitStatus session statusStopping)
                releaseHold recorder (GrantIntent 2)
              result ← tryWithContext @SomeException (runSession (scenarioSpec env' (recordingHarness recorder noHarness)) (putMVar handle))
              case result of
                Left (ExceptionWithContext attached raised) → do
                  -- the cancellation is what is raised, with the owner's retained cleanup beside it
                  fromException raised `shouldBe` Just ThreadKilled
                  map displayCleanupFailure (cleanupFailuresInContext attached) `shouldSatisfy` any ("close failed" `isInfixOf`)
                Right _ → expectationFailure "the cancellation was lost"
              -- the drain was reached and the role retired, whatever the sink did
              points ← recorded recorder
              points `shouldSatisfy` elem (Draining Gameplay)
              session ← readMVar handle
              status ← statusNow session
              fmap rolePhase (gameplayOf status) `shouldBe` Just Retired
              -- and the cleanup was accounted once, even when writing about it failed
              found ← atomically (sessionOutcomeNow session)
              length [entry | entry ← maybe [] pure (erPrimary (outEngine found)) <> erSecondary (outEngine found), eeCode entry == CleanupFailure, Text.isInfixOf "close failed" (eeMessage entry)] `shouldBe` 1
          pure ()
    )
    ["session stopping", "session engine failure"]

  mapM_
    ( \message →
        it ("records a driver failure and every retained cleanup when the diagnostic sink raises for \"" <> Text.unpack message <> "\"") $ do
          _ ←
            fatalSetup (setup (roleScript suspending)) {suShape = GameplayAlone} $ \env → do
              let world = seWorld env
              armed ← newTVarIO True
              let env' = env {seSpec = (seSpec env) {sxLogger = throwingLogger armed message}}
              recorder ← newRecorder
              failAt recorder (GrantIntent 2) (toException (userError "the driver failed"))
              (ended, session) ← runCaught env' (recordingHarness recorder noHarness) $ \_ session → do
                awaitPhase session Gameplay Running
                awaitRegistration world 1000
                passTime world 1000000 (elem "suspended" <$> outLines world)
                nudgeArmed world 1000 1000000
                void (awaitStatus session statusStopping)
              raisedMessage ended `shouldSatisfy` Text.isInfixOf "the driver failed"
              outcome ← outcomeNow session
              let entries = maybe [] pure (erPrimary (outEngine outcome)) <> erSecondary (outEngine outcome)
              outVerdict outcome `shouldBe` VerdictFailure
              outRetired outcome `shouldBe` True
              fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
              length [entry | entry ← entries, eeCode entry == CleanupFailure, Text.isInfixOf "close failed" (eeMessage entry)] `shouldBe` 1
              -- the sink's failure is evidence and not an entry of the engine report; for the last note the writer may have been
              -- abandoned before it was asked, and then the note is recorded as not delivered
              ( any (Text.isInfixOf "a diagnostic could not be written") (deSinkFirst (outDiagnostics outcome))
                  || any (Text.isInfixOf message) (deUndeliveredFirst (outDiagnostics outcome))
                )
                `shouldBe` True
              entries `shouldSatisfy` all (not . Text.isInfixOf "a diagnostic could not be written" . eeMessage)
          pure ()
    )
    ["session stopping", "session engine failure", "session ended"]

  it "keeps the success of an init the driver was not looking at when the session is cancelled instead of resumed" $
    withSetup ((setup (roleScript printScript {scUpdate = ["error('the first refresh fails')"]})) {suShape = PresentationAlone}) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      holdAt recorder (Resumed (InstanceKey Presentation 0))
      self ← myThreadId
      handle ← newEmptyMVar
      _ ← forkIO $ do
        session ← readMVar handle
        awaitPoint recorder (Resumed (InstanceKey Presentation 0))
        pumpUntil world (elem "init presentation" <$> outLines world)
        awaitRegistration world 1000000
        passTime world 1000000000 (maybe False roleFailed . presentationOf <$> statusNow session)
        throwTo self ThreadKilled
      result ← try (runSession (scenarioSpec env (recordingHarness recorder noHarness)) (putMVar handle))
      case result of
        Left (found ∷ SomeException) → fromException found `shouldBe` Just ThreadKilled
        Right _ → expectationFailure "the cancellation was lost"
      session ← readMVar handle
      status ← statusNow session
      fmap roleInitialized (presentationOf status) `shouldBe` Just True
      fmap rolePhase (presentationOf status) `shouldBe` Just Retired

  it "ends the session when the host fails while the entries are still being evaluated, before any root is dispatched" $ do
    _ ←
      fatalSetup (setup (roleScript printScript {scPrelude = ["print('load')"]})) $ \env → do
        let world = seWorld env
        failSinkOn world "load"
        outcome ← runScenario env $ \session → void (awaitRetired session)
        out ← outLines world
        out `shouldNotSatisfy` any ("init" `Text.isPrefixOf`)
        outVerdict outcome `shouldBe` VerdictFailure
        outRetired outcome `shouldBe` True
        fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just HostFailure
    pure ()

  it "ends even a previously healthy presentation role when the logical role's cleanup then fails" $ do
    _ ←
      fatalSetup
        (setup (roleScript closing)) {suHarness = noHarness {harnessSecond = [Gameplay]}}
        $ \env → do
          let world = seWorld env
          outcome ← runScenario env $ \session → do
            awaitPhase session Gameplay Running
            awaitPhase session Presentation Running
            awaitRegistration world 1000
            -- the second instance suspends with a closing handler that fails; the first instance fails at tick 2
            nudge world 2000000
            void (awaitRetired session)
          out ← outLines world
          out `shouldSatisfy` elem "shutdown presentation stopped"
          outVerdict outcome `shouldBe` VerdictFailure
          fmap rfRole (outFailures outcome) `shouldSatisfy` (Gameplay `elem`)
          fmap eeCode (erPrimary (outEngine outcome)) `shouldBe` Just LuaError
          fmap eeCode (erSecondary (outEngine outcome)) `shouldSatisfy` (CleanupFailure `elem`)
    pure ()
  where
    -- A logger whose sink raises, once armed, for the entries with this message.
    throwingLogger ∷ TVar Bool → Text → Logger
    throwingLogger armed message =
      mkLogger defaultLogFilter . callbackSink $ \entry →
        when (entryMessage entry == message) $ do
          live ← readTVarIO armed
          when live (throwIO (userError "the diagnostic sink failed"))
    suspending =
      printScript
        { scInit = []
        , scUpdate =
            [ "if api.time.tick() == 1 then"
            , "  print('suspended')"
            , "  local guard <close> = setmetatable({}, {__close = function() error('close failed') end})"
            , "  api.time.wait_ticks(100)"
            , "end"
            ]
        }
    closing =
      printScript
        { scInit = []
        , scUpdate =
            [ "if api.role == 'gameplay' then"
            , "  if api.instance_id == 'inst-1' then"
            , "    if api.time.tick() == 2 then error('boom') end"
            , "  else"
            , "    local guard <close> = setmetatable({}, {__close = function() error('close failed') end})"
            , "    api.time.wait_ticks(100)"
            , "  end"
            , "end"
            ]
        }

-- What is not a failure -------------------------------------------------------------------------------------------------------------

notFailures ∷ Spec
notFailures = describe "that are not failures" $ do
  it "leaves a session healthy when an optional request fails or a script catches an ordinary validation error" $
    withSetup
      (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then self.optional = api.content.data('lua/missing.bin', {optional = true}) end"], scShutdown = [], scUpdate = ["if api.role == 'gameplay' then local ok = pcall(api.content.module, 'bad\\\\path'); print('caught ' .. tostring(ok)); print('optional ' .. api.request.take(self.optional).status) end"]}))
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitRegistration world 1000
          passTime world 1000000 (elem "optional failure" <$> outLines world)
          status ← statusNow session
          fmap roleFailed (gameplayOf status) `shouldBe` Just False
          fmap roleFailed (presentationOf status) `shouldBe` Just False
          requestStop session StopQuit
        out ← outLines world
        out `shouldSatisfy` elem "caught false"
        outVerdict outcome `shouldBe` VerdictSuccess
        outFailures outcome `shouldBe` []

-- The finite releases of a role ---------------------------------------------------------------------------------------------------

-- | A harness that records, with these protections removed.
recording ∷ Recorder → Harness
recording recorder = recordingHarness recorder noHarness

releases ∷ Spec
releases = describe "the releases a role registered" $ do
  it "ends the whole session, with the healthy presentation role asked to stop, when a release of the retiring logical role fails; the logical role is not published retired" $
    withSetup (setup (roleScript (failingAt 2))) $ \env → do
      let world = seWorld env
      recorder ← newRecorder
      failAt recorder (Released (ReleaseBuild Gameplay BuildFacade)) (toException (userError "the gameplay facade's release failed"))
      (ended, session) ← runCaught env (recording recorder) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        passTime world 2000000 (elem "tick 2" <$> outLines world)
        -- the logical role fails, retires; one of its releases fails; the whole session is then asked to stop
        void (awaitStatus session (maybe False ((== Retired) . rolePhase) . presentationOf))
      ended `shouldSatisfy` either (const False) (const True)
      out ← outLines world
      out `shouldSatisfy` elem "shutdown presentation stopped"
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "the gameplay facade's release failed")
      history ← historyNow session
      historyStopped history `shouldBe` [Gameplay, Presentation]
      status ← statusNow session
      fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
      fmap rolePhase (presentationOf status) `shouldBe` Just Retired
      outRetired found `shouldBe` False

  it "attempts every other release when one fails: each of the two roles' four, the timer's and the composition's" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Released (ReleaseBuild Presentation BuildData)) (toException (userError "a release failed"))
      (ended, session) ← runCaught env (recording recorder) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitStatus session (maybe False ((== Retired) . rolePhase) . gameplayOf))
      ended `shouldSatisfy` either (const False) (const True)
      points ← recorded recorder
      let releasedWhich = [release | Released release ← points]
      length releasedWhich `shouldBe` 10
      releasedWhich `shouldSatisfy` elem ReleaseTimer
      releasedWhich `shouldSatisfy` elem ReleaseComposition
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      status ← statusNow session
      -- the role whose release failed is not proven retired; the other is
      fmap rolePhase (presentationOf status) `shouldBe` Just Stopping
      fmap rolePhase (gameplayOf status) `shouldBe` Just Retired

  describe "with the attempts given up at the first failure (a negative control)" $
    it "leaves the releases behind the failed one unattempted, which the proof above detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        failAt recorder (Released (ReleaseBuild Presentation BuildData)) (toException (userError "a release failed"))
        (_, session) ← runCaught env ((recording recorder) {harnessRemoved = [ProtectReleases]}) $ \_ session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
          void (awaitStatus session (maybe False ((== Retired) . rolePhase) . gameplayOf))
        points ← recorded recorder
        -- the presentation coordinator's release came after the failed one and was never attempted
        length [() | Released _ ← points] `shouldBe` 9
        [() | Released (ReleaseBuild Presentation BuildCoordinator) ← points] `shouldBe` []
        found ← outcomeNow session
        outVerdict found `shouldBe` VerdictFailure

  describe "with an exception of an asynchronous type taken for a cancellation (a negative control)" $
    it "raises a cancellation for what a release itself raised, which the proof of its source detects" $
      withSetup (setup (roleScript printScript)) $ \env → do
        recorder ← newRecorder
        failAt recorder (Released (ReleaseBuild Gameplay BuildFacade)) (toException ThreadKilled)
        (ended, _) ← runCaught env ((recording recorder) {harnessRemoved = [ProtectReleaseSource]}) $ \_ session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
        raisedKilled ended `shouldBe` True

  it "accounts a failure of the outermost release of the composition, and every role is still retired" $
    withSetup (setup (roleScript printScript)) $ \env → do
      recorder ← newRecorder
      failAt recorder (Released ReleaseComposition) (toException (userError "the outer scope failed to exit"))
      (ended, session) ← runCaught env (recording recorder) $ \_ session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopQuit
        void (awaitRetired session)
      ended `shouldSatisfy` either (const False) (const True)
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "the outer scope failed to exit")
      outRetired found `shouldBe` True

  it "accounts a failure to cancel the pacing timer, raises it, and still retires every role" $
    withSetup (setup (roleScript printScript)) {suShape = GameplayAlone} $ \env → do
      let world = seWorld env
          failing = case worldTimer world of
            TimerBackend arm → TimerBackend $ \microseconds wake → arm microseconds wake >>= \cancel → pure (cancel >> throwIO (userError "timer cancel failed"))
          env' = env {seSpec = (seSpec env) {sxTimer = failing}}
      (ended, session) ← runCaught env' noHarness $ \_ session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        requestStop session StopQuit
        void (awaitRetired session)
      raisedMessage ended `shouldSatisfy` Text.isInfixOf "timer cancel failed"
      found ← outcomeNow session
      outVerdict found `shouldBe` VerdictFailure
      outcomeMessages found `shouldSatisfy` any (Text.isInfixOf "timer cancel failed")
      outRetired found `shouldBe` True

  mapM_
    ( \point →
        it ("goes on to release and retire every role when the driver is cancelled right after " <> show point) $
          withSetup (setup (roleScript printScript)) $ \env → do
            recorder ← newRecorder
            holdAt recorder point
            (ended, session) ← runCaught env (recording recorder) $ \driver session → do
              awaitPhase session Gameplay Running
              awaitPhase session Presentation Running
              requestStop session StopQuit
              awaitPoint recorder point
              throwTo driver ThreadKilled
              releaseHold recorder point
            raisedKilled ended `shouldBe` True
            found ← outcomeNow session
            outRetired found `shouldBe` True
            outVerdict found `shouldBe` VerdictSuccess
            points ← recorded recorder
            length [() | Released _ ← points] `shouldBe` 10
    )
    [Committed "OwnerFinalized", Committed "Drained", Committed "ReleasesDone", Committed "RoleRetired"]

-- How a session ends -------------------------------------------------------------------------------------------------------------

outcomes ∷ Spec
outcomes = describe "how a session ends, in every arrangement of roles" $
  mapM_
    ( \shape → do
        let roles = case shape of
              BothRoles' → [Gameplay, Presentation]
              GameplayAlone → [Gameplay]
              PresentationAlone → [Presentation]
            first = if shape == PresentationAlone then Presentation else Gameplay
            running session = mapM_ (\role → awaitPhase session role Running) roles
        describe (show shape) $ do
          it "returns a success after a quit" $
            withSetup (setup (roleScript printScript)) {suShape = shape} $ \env → do
              outcome ← runScenario env $ \session → running session >> requestStop session StopQuit
              outVerdict outcome `shouldBe` VerdictSuccess
              outRetired outcome `shouldBe` True
          it "returns an interruption after an interrupt" $
            withSetup (setup (roleScript printScript)) {suShape = shape} $ \env → do
              outcome ← runScenario env $ \session → running session >> requestStop session StopInterrupt
              outVerdict outcome `shouldBe` VerdictInterrupted
          it "closes the whole session when an owner is stopped by someone else, and makes that neither a failure nor a quit" $
            withSetup (setup (roleScript printScript)) {suShape = shape} $ \env → do
              handles ← newTVarIO Map.empty
              let harness = noHarness {harnessOwner = \role found → atomically (modifyTVar' handles (Map.insert role found))}
              (ended, session) ← runCaught env harness $ \_ session → do
                running session
                found ← readTVarIO handles
                maybe (expectationFailure "no owner was told") ownerStop (Map.lookup first found)
                void (awaitRetired session)
              ended `shouldSatisfy` either (const False) (const True)
              outcome ← outcomeNow session
              outVerdict outcome `shouldBe` VerdictSuccess
              outQuit outcome `shouldBe` False
              out ← outLines (seWorld env)
              -- the peer is not left running without a driver
              length [line | line ← out, "shutdown" `Text.isPrefixOf` line] `shouldBe` length roles
          it "is a failure of the host when an owner is cancelled, which nothing asked for" $
            withSetup (setup (roleScript printScript)) {suShape = shape} $ \env → do
              handles ← newTVarIO Map.empty
              let harness = noHarness {harnessOwner = \role found → atomically (modifyTVar' handles (Map.insert role found))}
              (_, session) ← runCaught env harness $ \_ session → do
                running session
                found ← readTVarIO handles
                maybe (expectationFailure "no owner was told") ownerCancel (Map.lookup first found)
                void (awaitRetired session)
              outcome ← outcomeNow session
              outVerdict outcome `shouldBe` VerdictFailure
              outcomeMessages outcome `shouldSatisfy` any (Text.isInfixOf "cancelled")
          it "raises what the driver threw when it throws, whichever role is built last, with every role retired" $
            withSetup (setup (roleScript printScript)) {suShape = shape} $ \env → do
              recorder ← newRecorder
              failAt recorder (Intended (InstanceKey first 0)) (toException (userError "the driver failed"))
              (ended, session) ← runCaught env (recording recorder) $ \_ session → void (awaitStatus session statusStopping)
              raisedMessage ended `shouldSatisfy` Text.isInfixOf "the driver failed"
              outcome ← outcomeNow session
              outVerdict outcome `shouldBe` VerdictFailure
              outRetired outcome `shouldBe` True
    )
    [BothRoles', GameplayAlone, PresentationAlone]

-- | The bounds a session publishes failures within.
published ∷ FailureLimits
published = failureLimitsOf fixedM1Profile
