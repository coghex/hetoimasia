{-# LANGUAGE OverloadedStrings #-}

-- | What a session keeps of its failures: the first failure of a role is the role's whatever follows, every
-- failure is accounted, diagnostics are bounded at code points, and a failure outranks an interruption however
-- the two arrive.
module Test.LuaEngine.Session.Evidence (spec) where

import Control.Monad (void)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Session.Support

spec ∷ Spec
spec = describe "evidence" $ do
  it "keeps a role's first failure and its attribution while a later failure of the same role is accounted beside it" $
    withSetup
      ( (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'gameplay' and api.instance_id == 'inst-1' then error('first failure') end"], scShutdown = ["if api.instance_id == 'inst-2' then error('second failure') end"]}))
          { suShape = GameplayAlone
          , suHarness = noHarness {harnessSecond = [Gameplay]}
          }
      )
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitRegistration world 1000
          nudge world 1000000
          void (awaitRetired session)
        case outFailures outcome of
          [found] → do
            rfInstance found `shouldBe` Just "inst-1"
            rfMessage found `shouldSatisfy` Text.isInfixOf "first failure"
            rfStage found `shouldBe` OnUpdate
          other → expectationFailure ("expected the first failure alone, found " <> show other)
        -- the sibling's failure to shut down is accounted, in order, beside the first and does not replace it
        let report = outEngine outcome
        fmap (Text.isInfixOf "first failure" . eeMessage) (erPrimary report) `shouldBe` Just True
        map eeMessage (erSecondary report) `shouldSatisfy` any (Text.isInfixOf "second failure")
        reportAccounted report `shouldBe` 2

  it "holds a script's diagnostic, whatever its text, to the bounds, and keeps the record whole" $
    withSetup ((setup (roleScript printScript {scInit = [], scUpdate = ["error(string.rep('\\xC3\\xA9', 5000))"]})) {suShape = GameplayAlone}) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitRetired session)
      case outFailures outcome of
        [found] → do
          utf8Bytes (rfMessage found) `shouldSatisfy` (<= 2048)
          Text.unpack (rfMessage found) `shouldSatisfy` all (/= '\xFFFD')
          maybe 0 utf8Bytes (rfTraceback found) `shouldSatisfy` (<= 8192)
          recordBytes found `shouldSatisfy` (<= 16384)
          rfCode found `shouldBe` LuaError
          rfRole found `shouldBe` Gameplay
        other → expectationFailure ("expected one failure, found " <> show other)

  it "cuts the diagnostic of a terminal failure at a code point, ending in a visible marker, before it is published" $
    withSetup (setup (roleScript printScript)) $ \env → do
      let wide = Text.replicate 6000 "\x20AC"
          terminal = (newRoleFailure StateUnavailable OnUpdate Presentation wide) {rfTraceback = Just wide, rfInstance = Just (Text.replicate 400 "i")}
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        void (latchTerminalFailure session terminal)
        void (awaitRetired session)
      case outTerminal outcome of
        Just found → do
          utf8Bytes (rfMessage found) `shouldSatisfy` (<= 2048)
          rfMessage found `shouldSatisfy` Text.isSuffixOf "..."
          Text.unpack (rfMessage found) `shouldSatisfy` all (/= '\xFFFD')
          maybe 0 utf8Bytes (rfTraceback found) `shouldSatisfy` (<= 8192)
          maybe 0 utf8Bytes (rfInstance found) `shouldSatisfy` (<= 128)
          recordBytes found `shouldSatisfy` (<= 16384)
          rfCode found `shouldBe` StateUnavailable
        Nothing → expectationFailure "the terminal failure was not published"

  it "lets a failure outrank an interruption: a hook that fails while the interrupted session stops makes the outcome a failure, and the interruption is still recorded" $
    withSetup (setup (roleScript printScript {scShutdown = ["if api.role == 'gameplay' then error('shutdown failed') end"]})) $ \env → do
      outcome ← runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        requestStop session StopInterrupt
        void (awaitRetired session)
      outVerdict outcome `shouldBe` VerdictFailure
      outInterrupted outcome `shouldBe` True
      outQuit outcome `shouldBe` False
      fmap rfStage (outFailures outcome) `shouldBe` [OnShutdown]
      fmap rfRole (outFailures outcome) `shouldBe` [Gameplay]

  it "ranks an interruption over a normal quit when both are asked, whichever comes first" $
    mapM_
      ( \order → withSetup (setup (roleScript printScript)) $ \env → do
          outcome ← runScenario env $ \session → do
            awaitPhase session Gameplay Running
            awaitPhase session Presentation Running
            mapM_ (requestStop session) order
          outVerdict outcome `shouldBe` VerdictInterrupted
          outQuit outcome `shouldBe` True
          outInterrupted outcome `shouldBe` True
      )
      [[StopQuit, StopInterrupt], [StopInterrupt, StopQuit]]

  it "publishes a failure through the outcome endpoint as soon as it latches, before the session has ended" $
    withSetup (setup (roleScript printScript {scInit = [], scUpdate = ["if api.role == 'gameplay' then error('boom') end"]})) $ \env → do
      let world = seWorld env
      void . runScenario env $ \session → do
        awaitPhase session Gameplay Running
        awaitPhase session Presentation Running
        awaitRegistration world 1000
        nudge world 1000000
        void (awaitStatus session (maybe False roleFailed . gameplayOf))
        now ← outcomeNow session
        outVerdict now `shouldBe` VerdictFailure
        outRetired now `shouldBe` False
        fmap rfRole (outFailures now) `shouldBe` [Gameplay]
        requestStop session StopQuit
