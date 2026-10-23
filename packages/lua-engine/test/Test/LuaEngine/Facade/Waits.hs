{-# LANGUAGE OverloadedStrings #-}

-- | Cooperative waits and the exact arithmetic behind them (P-72 section 3, P-74 section 5): a presentation
-- wait is the exact value of the number times 1,000,000,000, rounded up, as a positive 64-bit count of
-- nanoseconds, whose deadline the scheduler places when the wait is requested; a wake before the deadline
-- resumes nothing and a resumption may be late; a gameplay wait is a whole number of future ticks. A tick no Lua
-- integer holds is an engine failure and is never wrapped.
module Test.LuaEngine.Facade.Waits (spec) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support

files ∷ [(FilePath, ByteString)]
files = [("data.bin", "xx")]

-- | A presentation behavior whose first update prints, waits this many seconds (written as Lua) and prints
-- again; its cadence is one second.
waiter ∷ Text → Script
waiter seconds =
  script
    { scUpdate =
        [ "if self.ran then return end self.ran = true"
        , "print('before dt ' .. dt)"
        , "api.time.wait_seconds(" <> seconds <> ")"
        , "print('after dt ' .. dt .. ' at ' .. api.time.seconds())"
        ]
    }

second ∷ Word64
second = 1000000000

-- | Run the waiter to its wait: the update is due one second after init, and the wait is requested at the
-- clock then.
toTheWait ∷ World → Fvm → IO ()
toTheWait world fvm = do
  setClock world second
  pumpUntil world (elem "before dt 1.0" <$> outLines world)
  awaitWaiting fvm 1

-- | Wake the owner, with the clock where it is, and wait until it has looked at the clock and armed again.
wakeAndSettle ∷ World → IO ()
wakeAndSettle world = do
  armed ← armedTimers world
  fireTimers world
  awaitArmed world (armed + 1)

-- | The waiter must still be waiting.
stillWaiting ∷ World → Expectation
stillWaiting world = outLines world >>= (`shouldBe` ["before dt 1.0"])

spec ∷ Spec
spec = describe "waits" $ do
  describe "wait_seconds" $ do
    it "resumes after the exact count of nanoseconds, rounded up: a tiny positive wait is one nanosecond, never none" $
      withOneIn Presentation fixedM1Profile (waiter "1e-12") files $ \world _ fvm _ → do
        toTheWait world fvm
        wakeAndSettle world
        stillWaiting world
        setClock world (second + 1)
        pumpUntil world (elem "after dt 1.0 at 1.000000001" <$> outLines world)
    it "converts the exact value of a double: a tenth is a nanosecond past a tenth of a second" $
      withOneIn Presentation fixedM1Profile (waiter "0.1") files $ \world _ fvm _ → do
        toTheWait world fvm
        setClock world (second + 100000000)
        wakeAndSettle world
        stillWaiting world
        setClock world (second + 100000001)
        pumpUntil world (elem "after dt 1.0 at 1.100000001" <$> outLines world)
    it "takes an integer of seconds exactly" $
      withOneIn Presentation fixedM1Profile (waiter "2") files $ \world _ fvm _ → do
        toTheWait world fvm
        setClock world (3 * second - 1)
        wakeAndSettle world
        stillWaiting world
        setClock world (3 * second)
        pumpUntil world (elem "after dt 1.0 at 3.0" <$> outLines world)
    it "does not resume on an early wake, resumes late when the owner is late, and keeps the update's dt" $
      withOneIn Presentation fixedM1Profile (waiter "0.5") files $ \world _ fvm _ → do
        toTheWait world fvm
        wakeAndSettle world
        stillWaiting world
        setClock world (second + 250000000)
        wakeAndSettle world
        stillWaiting world
        -- the wake comes late: the segment that resumes sees the time it really is
        setClock world (7 * second)
        pumpUntil world (elem "after dt 1.0 at 7.0" <$> outLines world)
    it "places the deadline when the wait is requested and not at the segment's sample" $
      withOneIn Presentation fixedM1Profile
        script
          { scUpdate =
              [ "if self.ran then return end self.ran = true"
              , "print('begun')"
              , "api.time.wait_seconds(0.5)"
              , "print('resumed')"
              ]
          }
        files
        $ \world _ fvm _ → do
          -- every read of the clock moves it on, so the clock has moved on from the segment's sample by the
          -- time the wait is requested
          setClockStep world 10000000
          setClock world second
          pumpUntil world (elem "begun" <$> outLines world)
          awaitWaiting fvm 1
          -- the sample was taken at or after one second: exactly half a second after one second is too early
          setClockStep world 0
          setClock world (second + 500000000)
          wakeAndSettle world
          outLines world >>= (`shouldBe` ["begun"])
          setClock world (second + 600000000)
          pumpUntil world (elem "resumed" <$> outLines world)
    it "accepts a wait longer than a Lua integer holds nanoseconds for, and resumes it when the clock gets there" $
      withOneIn Presentation fixedM1Profile (waiter "1e10") files $ \world _ fvm _ → do
        toTheWait world fvm
        -- ten billion seconds is 1e19 nanoseconds, past 2^63 - 1 and within 2^64 - 1
        setClock world (second + 9999999999999999999)
        wakeAndSettle world
        stillWaiting world
        setClock world (second + 10000000000000000000)
        pumpUntil world (any (Text.isPrefixOf "after dt 1.0") <$> outLines world)
    it "refuses, as an ordinary error and before suspending anything, a wait whose deadline the clock cannot count" $
      withOneIn Presentation fixedM1Profile
        script
          { scEverySeconds = "0.1"
          , scUpdate =
              [ "if self.ran then return end self.ran = true"
              , "try('past the clock', function() return api.time.wait_seconds(2) end)"
              , "try('still room', function() return api.time.wait_seconds(0.25) end)"
              , "print('resumed')"
              ]
          }
        files
        $ \world _ fvm _ → do
          -- the clock is a second and a fifth short of the end of its range when the update falls due: a tenth of a
          -- second more is still counted, two seconds are not
          setClock world (18446744073709551615 - 1200000000)
          pumpUntil world (any ("past the clock" `Text.isPrefixOf`) <$> outLines world)
          awaitWaiting fvm 1
          outLines world >>= (`shouldSatisfy` (\found → any (\line → "past the clock => false ; " `Text.isPrefixOf` line && "past the clock's range" `Text.isInfixOf` line) found))
          outLines world >>= (`shouldNotSatisfy` elem "resumed")
  describe "wait_ticks" $ do
    it "suspends the update for that many future ticks, keeps its dt, and starts no second update meanwhile" $
      withOneIn Gameplay fixedM1Profile
        script
          { scUpdate =
              [ "print('update at ' .. api.time.tick() .. ' dt ' .. dt)"
              , "if not self.waited then"
              , "  self.waited = true"
              , "  api.time.wait_ticks(3)"
              , "  print('resumed at ' .. api.time.tick() .. ' dt ' .. dt)"
              , "end"
              ]
          }
        files
        $ \world control fvm _ → do
          tickBy control fvm 6
          outLines world
            >>= ( `shouldBe`
                    [ "update at 1 dt 1e-09"
                    , "resumed at 4 dt 1e-09"
                    , "update at 5 dt 1e-09"
                    , "update at 6 dt 1e-09"
                    ]
                )
    it "accepts a count that ends exactly at the largest tick, and suspends" $
      withOneIn Gameplay fixedM1Profile
        script
          { scUpdate = ["if self.ran then return end self.ran = true", "api.time.wait_ticks(math.maxinteger - api.time.tick())", "print('unreachable')"]
          }
        files
        $ \world control fvm spawned → do
          tickBy control fvm 2
          awaitWaiting fvm 1
          phaseOf spawned >>= (`shouldNotBe` Nothing)
          outLines world >>= (`shouldBe` [])
  describe "exhaustion" $
    it "is an engine failure through the injected boundary when a tick no Lua integer holds is asked for, and is never wrapped" $ do
      (reported, _) ←
        fatalWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scUpdate = ["print('tick ' .. api.time.tick())"]}) : files)) $ \world control runtime →
          withFvm world runtime gameplayShape $ \fvm → do
            _ ← spawn world fvm "modules-test" mainPath
            setTickOverride world (Just 9223372036854775808)
            tickBy control fvm 1
      length reported `shouldBe` 1
      reported `shouldSatisfy` all (\(EngineFailure why) → "past the largest Lua integer" `Text.isInfixOf` why)
