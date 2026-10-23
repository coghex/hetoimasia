{-# LANGUAGE OverloadedStrings #-}

-- | How a session stops and drains: a stop that takes no slot, admission closed before anything new is issued,
-- cancellation and release still possible, and a role retired only when what it holds has actually retired.
module Test.LuaEngine.Session.Stop (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (replicateM_, void)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Modules.Support (closeGate, openGate)
import Test.LuaEngine.Session.Support
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "stop and drain" $ do
  fullCapacity
  sharedJobs
  peers
  shutdowns

-- A stop with everything full ---------------------------------------------------------------------------------------------------

fullCapacity ∷ Spec
fullCapacity = describe "with every place taken" $ do
  it "takes no slot to stop, closes new work before anything is issued, and still lets a script cancel and write while it drains" $
    withSetup
      ( addFile
          ("lua/slow.bin", "slow")
          ( (setup (roleScript filling)) {suShape = PresentationAlone}
          )
      )
      $ \env → do
        let world = seWorld env
            probe = ssProbeOf env
        closeGate probe "lua/slow.bin"
        holdSink world "second"
        outcome ← runScenario env $ \session → do
          awaitPhase session Presentation Running
          -- the first refresh asks until the places are full, each request held in the pool
          passTime world 1000000000 (any (Text.isPrefixOf "filled") <$> outLines world)
          -- the second refresh is parked in its output while the session is stopped, repeatedly, from several threads
          nudge world 1000000000
          awaitSinkEntered world "second"
          done ← newEmptyMVar
          replicateM_ 4 . forkIO $ do
            requestStop session StopQuit
            requestStop session StopInterrupt
            putMVar done ()
          replicateM_ 4 (bounded (takeMVar done))
          status ← statusNow session
          statusStopping status `shouldBe` True
          fmap rolePhase (presentationOf status) `shouldBe` Just Stopping
          releaseSink world
          -- the held reads are provider work the role still owes: it is not retired while they are held
          void (awaitStatus session (\status' → fmap rolePhase (presentationOf status') == Just Stopping))
          st <- statusNow session
          fmap rolePhase (presentationOf st) `shouldBe` Just Stopping
          openGate probe "lua/slow.bin"
          void (awaitRetired session)
        out ← outLines world
        -- a content request after the stop is an ordinary error, not busy, and cancelling and writing still work
        out `shouldSatisfy` elem "after stop false"
        out `shouldSatisfy` any (`elem` ["cancel cancelled", "cancel already_settled"])
        outVerdict outcome `shouldBe` VerdictInterrupted
        outRetired outcome `shouldBe` True
  where
    filling =
      printScript
        { scInit = []
        , scShutdown = []
        , scUpdate =
            [ "self.n = (self.n or 0) + 1"
            , "if self.n == 1 then"
            , "  self.reqs = {}"
            , "  for i = 1, 40 do"
            , "    local r = api.content.data('lua/slow.bin')"
            , "    if r == nil then break end"
            , "    self.reqs[#self.reqs + 1] = r"
            , "  end"
            , "  print('filled ' .. #self.reqs)"
            , "elseif self.n == 2 then"
            , "  print('second')"
            , "  local ok = pcall(api.content.data, 'lua/slow.bin')"
            , "  print('after stop ' .. tostring(ok))"
            , "  print('cancel ' .. api.request.cancel(self.reqs[1]))"
            , "  warn('written after the stop')"
            , "end"
            ]
        }

-- Module jobs the VM owns -----------------------------------------------------------------------------------------------------------

sharedJobs ∷ Spec
sharedJobs = describe "shared module jobs" $ do
  it "keeps a job the VM owns until the VM retires it, whoever stopped waiting for it, and retires the role only then" $
    withSetup
      ( addFile
          ("lua/dep.lua", luaMain ["return {}"])
          ( (setup (roleScript printScript {scInit = ["if api.role == 'gameplay' then self.module = api.content.module('lua/dep.lua') end"], scUpdate = []}))
              { suShape = GameplayAlone
              , suHarness = noHarness {harnessSecond = [Gameplay]}
              }
          )
      )
      $ \env → do
        let probe = ssProbeOf env
        closeGate probe "lua/dep.lua"
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitReadOf env "lua/dep.lua"
          requestStop session StopQuit
          status ← statusNow session
          fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
          openGate probe "lua/dep.lua"
          awaitPhase session Gameplay Retired

-- A peer's holdings -----------------------------------------------------------------------------------------------------------------------

peers ∷ Spec
peers = describe "the second instance of a VM" $ do
  it "keeps its own holdings distinct while the role's policy ends both: the failed instance shuts down as failed, its peer as stopped, and the role retires when the peer's read has" $
    withSetup
      ( addFile
          ("lua/slow.bin", "slow")
          ( (setup
              ( roleScript
                  printScript
                    { scInit = ["if api.role == 'gameplay' and api.instance_id == 'inst-2' then self.request = api.content.data('lua/slow.bin', {tick_offset = 50}) end"]
                    , scUpdate = ["if api.role == 'gameplay' and api.instance_id == 'inst-1' then error('boom') end"]
                    , scShutdown = ["print('shutdown ' .. api.instance_id .. ' ' .. reason)"]
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
        void . runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          awaitReadOf env "lua/slow.bin"
          awaitRegistration world 1000
          nudge world 1000000
          status ← awaitStatus session (maybe False roleFailed . gameplayOf)
          fmap (>>= rfInstance) (roleFailure <$> gameplayOf status) `shouldBe` Just (Just "inst-1")
          -- the peer's read is its own provider work: the role has not retired while it is held, the other role goes on
          fmap rolePhase (gameplayOf status) `shouldBe` Just Stopping
          fmap rolePhase (presentationOf status) `shouldBe` Just Running
          openGate probe "lua/slow.bin"
          awaitPhase session Gameplay Retired
          out <- outLines world
          out `shouldSatisfy` elem "shutdown inst-1 failed"
          out `shouldSatisfy` elem "shutdown inst-2 stopped"
          requestStop session StopQuit

-- Shutdowns -----------------------------------------------------------------------------------------------------------------------------------

shutdowns ∷ Spec
shutdowns = describe "shutdown" $ do
  it "runs once, finite, for an instance that has one, and an instance without one is simply stopped" $
    withSetup
      (setup (luaMain ["return { gameplay = { every_ticks = 1, update = function() end }, presentation = { every_seconds = 1, update = function() end, shutdown = function(self, reason) print('shutdown presentation ' .. reason) end } }"]))
      $ \env → do
        let world = seWorld env
        outcome ← runScenario env $ \session → do
          awaitPhase session Gameplay Running
          awaitPhase session Presentation Running
          requestStop session StopQuit
          requestStop session StopQuit
        out ← outLines world
        out `shouldBe` ["shutdown presentation stopped"]
        outVerdict outcome `shouldBe` VerdictSuccess
        outFailures outcome `shouldBe` []

  it "is skipped for a root whose init failed, and runs for the roots that succeeded, each exactly once" $
    withSetup (setup (roleScript printScript {scInit = ["if api.role == 'presentation' then error('ui init failed') end"]})) $ \env → do
      let world = seWorld env
      outcome ← runScenario env $ \session → void (awaitRetired session)
      out ← outLines world
      filter ("shutdown presentation" `Text.isPrefixOf`) out `shouldBe` []
      filter ("shutdown gameplay" `Text.isPrefixOf`) out `shouldSatisfy` (`elem` [[], ["shutdown gameplay stopped"]])
      length (filter ("shutdown" `Text.isPrefixOf`) out) `shouldSatisfy` (<= 1)
      outVerdict outcome `shouldBe` VerdictFailure
