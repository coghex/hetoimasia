{-# LANGUAGE OverloadedStrings #-}

-- | The role clocks (D-17, D-68, P-72 section 3): the gameplay tick, which only a begun tick advances; and
-- presentation time, sampled once for each hook and each resumed segment from one origin set when the VM
-- begins its first instance's initialization.
module Test.LuaEngine.Facade.Clocks (spec) where

import Data.ByteString (ByteString)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Modules.Support (awaitStarted, closeGate, openGate)

files ∷ [(FilePath, ByteString)]
files = [("lua/slow.lua", "return {id = 'slow'}"), ("data.bin", "xx")]

spec ∷ Spec
spec = describe "clocks" $ do
  describe "gameplay" $ do
    it "reads tick 0 in init, the granted tick in an update as a Lua integer, and the tick duration as numeric seconds" $
      withOneIn Gameplay fixedM1Profile
        script
          { scInit = ["print('init tick ' .. api.time.tick() .. ' ' .. math.type(api.time.tick()) .. ' ' .. api.time.tick_seconds() .. ' ' .. math.type(api.time.tick_seconds()))"]
          , scUpdate = ["print('update tick ' .. api.time.tick())"]
          , scShutdown = ["print('shutdown tick ' .. api.time.tick())"]
          }
        files
        $ \world control fvm spawned → do
          tickBy control fvm 2
          stopSpawned spawned
          _ ← settledOf spawned
          outLines world >>= (`shouldBe` ["init tick 0 integer 0.001 float", "update tick 1", "update tick 2", "shutdown tick 2"])
    it "does not move while a load is held: the tick waits for the load, and an instance made meanwhile starts at the tick the owner has reached" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource slowLoader) : files)) $ \world control runtime →
        withFvm world runtime gameplayShape $ \fvm → do
          closeGate (ssProbe (wSession world)) "lua/slow.lua"
          _ ← spawn world fvm "modules-test" mainPath
          tickBy control fvm 1
          -- the module asked for at tick 1 is due at tick 2, and its read is held
          awaitStarted (ssProbe (wSession world)) 2
          grantTick fvm
          _ ← spawn world fvm "modules-test" mainPath
          ownerTick fvm >>= (`shouldBe` 1)
          outLines world >>= (`shouldBe` ["inst-1 init tick 0", "inst-1 update tick 1", "inst-2 init tick 1"])
          openGate (ssProbe (wSession world)) "lua/slow.lua"
          awaitTickDone control fvm
          ownerTick fvm >>= (`shouldBe` 2)
          outLines world >>= (`shouldBe` ["inst-1 init tick 0", "inst-1 update tick 1", "inst-2 init tick 1", "inst-1 update tick 2", "inst-2 update tick 2"])

  describe "presentation" $ do
    it "reads zero in its first instance's init, the same origin in an instance made later, and the clock again in a shutdown" $
      withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scInit = ["print(api.instance_id .. ' init ' .. api.time.seconds() .. ' ' .. api.time.seconds())"], scShutdown = ["print(api.instance_id .. ' shutdown ' .. api.time.seconds())"]}) : files)) $ \world _ runtime →
        withFvm world runtime presentationShape $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          advanceClock world 5000000000
          later ← spawn world fvm "modules-test" mainPath
          advanceClock world 250000000
          stopSpawned later
          _ ← settledOf later
          outLines world >>= (`shouldBe` ["inst-1 init 0.0 0.0", "inst-2 init 5.0 5.0", "inst-2 shutdown 5.25"])
    it "takes one sample for a segment however the clock moves, and a new one when the segment resumes" $
      withOneIn Presentation fixedM1Profile
        script
          { scUpdate =
              [ "if self.ran then return end self.ran = true"
              , "local a, b = api.time.seconds(), api.time.seconds()"
              , "print('within a segment ' .. tostring(a == b))"
              , "api.time.yield()"
              , "local c = api.time.seconds()"
              , "print('after the yield ' .. tostring(c > a))"
              ]
          }
        files
        $ \world _ _ _ → do
          setClockStep world 1000000
          advanceClock world 1000000000
          pumpUntil world (elem "after the yield true" <$> outLines world)
          outLines world >>= (`shouldBe` ["within a segment true", "after the yield true"])
  where
    -- the first instance asks for a module in its first update; the second only reports
    slowLoader =
      script
        { scInit = ["print(api.instance_id .. ' init tick ' .. api.time.tick())"]
        , scUpdate =
            [ "if api.instance_id == 'inst-1' and not self.asked then self.asked = true api.content.module('lua/slow.lua') end"
            , "print(api.instance_id .. ' update tick ' .. api.time.tick())"
            ]
        }
