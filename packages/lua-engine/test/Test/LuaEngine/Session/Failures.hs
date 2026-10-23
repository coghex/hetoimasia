{-# LANGUAGE OverloadedStrings #-}

-- | The failure policy after the roots started: which failure ends which part of the session, what stays
-- running, and what a status read and the outcome say while it happens.
--
-- The failures are the real ones: a script that raises, a required request nothing ever polls, a provider
-- whose reader fails, a sink that raises, a cleanup that fails when the owner retires. The ones that end an
-- owner as a failure of the host are raised by supervision at its boundary as well, so those examples run
-- under 'fatalSetup' and assert the session's own account inside the body.
module Test.LuaEngine.Session.Failures (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (displayException, throwIO)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Worker (workerDefinition)
import Hetoimasia.Runtime.Supervision (Disposition (Required), Recognition (Unrecognized), Role (Service), SupervisedStart (WorkerStarted), WorkerPolicy (..), startSupervised)
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, injectedDefect, openGate)
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "failures" $ do
  logicalFailure
  otherFailures
  hostFailures
  notFailures

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
        passTime world 2000000 ((>= 2) . length <$> linesWith "tick" world)
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
        nudge world 5000000
        passTime world 1000000000 (elem "ui update" <$> outLines world)
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

-- The rest of the session ---------------------------------------------------------------------------------------------------------

otherFailures ∷ Spec
otherFailures = describe "that end the whole session" $ do
  it "ends the session when the presentation role fails, stopping the logical role in order" $
    withSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'presentation' then error('ui boom') end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        nudge world 1000000000
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
        nudge world 1000000000
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
          outcome ← runScenario env $ \session → do
            awaitPhase session Presentation Running
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
          nudge world 1000000000
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
