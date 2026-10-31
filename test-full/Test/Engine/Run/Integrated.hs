-- | LFE-23: the application composition's outcome boundary over combinations of endings the session's own examples cover one
-- at a time. The command's real composition ('Hetoimasia.Run.runGame': the production session coordinator over real content,
-- real filtered Lua VMs, the real module and data services and the real read pool, no graphics) is run in this process, and
-- each example states the exit status the contract gives: failure over interruption over a normal stop (D-26, D-42), and a
-- failure of cleanup after a start never a success.
--
-- These examples check the composition and the status it maps to, not another implementation of the session's policy: the
-- policy itself is in @lua-engine-tests@. The signal is the coordinator's own delivery; actual OS signals are the process
-- examples' (@Process@), and no example here acquires a native session. Nothing sleeps.
module Test.Engine.Run.Integrated (spec) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Engine.Run.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Integrated endings (LFE-23)" $ do
  ranking
  cleanup
  guarded

entry ∷ [Text] → Text
entry body = Text.unlines (["return {"] <> body <> ["}"])

-- | A logical role that does nothing and a UI that says it is ready.
quietLogic ∷ [Text]
quietLogic =
  [ "  gameplay = { every_ticks = 1, init = function(self, api) print('logic init') end, update = function(self, dt) end },"
  ]

-- | A UI that says it is ready and, once the logical role has failed, says so; with the given hooks around.
readyUi ∷ [Text] → [Text]
readyUi extra =
  [ "  presentation = {"
  , "    every_seconds = 0.02,"
  , "    init = function(self, api) print('ui ready') end,"
  , "    update = function(self, dt)"
  , "      local status = self.api.session.status()"
  , "      if status.gameplay and status.gameplay.failed and not self.said then self.said = true print('ui saw the failure') end"
  , "    end,"
  ]
    <> extra
    <> ["  }"]

files ∷ [Text] → Files
files body = [("hetoimasia.json", commonManifest), ("main.lua", lua (entry body))]

-- | A UI that quits as soon as the logical role has initialized.
quittingUi ∷ [Text]
quittingUi =
  [ "  presentation = {"
  , "    every_seconds = 0.02,"
  , "    init = function(self, api) print('ui ready') end,"
  , "    update = function(self, dt)"
  , "      local status = self.api.session.status()"
  , "      if status.gameplay and status.gameplay.initialized then print('ui quit') self.api.session.quit() end"
  , "    end"
  , "  }"
  ]

-- | What the outcome is when an ordinary end meets another, stated from the ranking of the contract and not computed.
ranking ∷ Spec
ranking = describe "failure over interruption over a normal stop" $ do
  it "is 0 for a normal quit from the UI alone" $ do
    observed ← observe (files (quietLogic <> quittingUi)) (\_ → pure ())
    observedStatus observed `shouldBe` ExitSuccess
    observedOut observed `shouldSatisfy` elem "ui quit"

  it "is 130 for an interruption alone, with the UI's shutdown run" $ do
    observed ← observe (files (quietLogic <> readyUi ["    shutdown = function(self, reason) print('ui shutdown') end"])) $ \probe → do
      probeAwaitOut probe "ui ready"
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 130
    observedOut observed `shouldSatisfy` elem "ui shutdown"

  it "is 130, never 0, when a quit is asked during the stop an interruption began" $ do
    observed ← observe (files (quietLogic <> readyUi ["    shutdown = function(self, reason) self.api.session.quit() print('ui shutdown') end"])) $ \probe → do
      probeAwaitOut probe "ui ready"
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 130

  forM_ [("an interruption", True), ("a later quit", False)] $ \(label, signal) →
    it ("is 1, never 130 or 0, when the logical role failed and then " <> label <> " ended the session") $ do
      let failing =
            [ "  gameplay = { every_ticks = 1, init = function(self, api) print('logic init') end, update = function(self, dt) error('logic broke') end },"
            ]
          ui = readyUi []
          quitAfter =
            [ "  presentation = {"
            , "    every_seconds = 0.02,"
            , "    init = function(self, api) print('ui ready') end,"
            , "    update = function(self, dt)"
            , "      local status = self.api.session.status()"
            , "      if status.gameplay and status.gameplay.failed then print('ui saw the failure') self.api.session.quit() end"
            , "    end"
            , "  }"
            ]
      observed ← observe (files (failing <> (if signal then ui else quitAfter))) $ \probe →
        if signal
          then probeAwaitOut probe "ui saw the failure" >> void (probeSignal probe)
          else pure ()
      observedStatus observed `shouldBe` ExitFailure 1
      observedOut observed `shouldSatisfy` elem "ui saw the failure"

-- | A cleanup that fails after a clean start is a failure, however the end was asked for.
cleanup ∷ Spec
cleanup = describe "a failure of cleanup" $
  it "is 1, not 130, when the logical role's suspended work fails to close while an interruption stops the session, and the report names it" $ do
    let suspended =
          [ "  gameplay = {"
          , "    every_ticks = 1,"
          , "    init = function(self, api) print('logic init') end,"
          , "    update = function(self, dt)"
          , "      if self.armed then return end"
          , "      self.armed = true"
          , "      local guard <close> = setmetatable({}, {__close = function() error('close failed') end})"
          , "      print('logic suspended')"
          , "      self.api.time.wait_ticks(1000)"
          , "    end"
          , "  },"
          ]
    observed ← observe (files (suspended <> readyUi [])) $ \probe → do
      probeAwaitOut probe "logic suspended"
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 1
    observedReports observed `shouldSatisfy` any (Text.isInfixOf "close failed")

-- | The unavailable-state guard caught by a script is terminal for the whole session.
guarded ∷ Spec
guarded = describe "the unavailable-state guard" $
  it "is 1 with one diagnostic when a logical update catches the error, though the UI is healthy and later quits" $ do
    let asking =
          [ "  gameplay = { every_ticks = 1, init = function(self, api) print('logic init') end,"
          , "    update = function(self, dt) pcall(state, 1) print('caught') end },"
          ]
    observed ← observe (files (asking <> readyUi [])) $ \probe → probeAwaitErr probe (Text.isInfixOf phrase)
    observedStatus observed `shouldBe` ExitFailure 1
    length (filter (Text.isInfixOf phrase) (observedErr observed)) `shouldBe` 1
  where
    phrase = "state service not available in this milestone"
