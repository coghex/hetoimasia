-- | The kind of an instance follows the module's entries, and what is refused as usage.
module Test.LuaRuntime.Runner.Kinds (spec) where

import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Runner
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (bounded, withBoundary)

oneShot, looped, eventOnly ∷ [Text.Text]
oneShot = ["function run(self) fx.record('run') end"]
looped = ["function update(self, dt) fx.record('update') end", "function shutdown(self, reason) fx.record('shutdown looped ' .. reason) end"]
eventOnly = ["function shutdown(self, reason) fx.record('shutdown event ' .. reason) end"]

spec ∷ Spec
spec = describe "kinds and usage" $ do
  it "runs a module with run as a one-shot, one with update on its interval as a looped instance and one with neither as an event-only instance" $ bounded $ do
    fixture ← newRFixture
    withScripts [("one.lua", lua oneShot), ("loop.lua", lua looped), ("event.lua", lua eventOnly)] $ \paths →
      withBoundary $ \_ runtime → do
        let scripts = [noWait (scriptAt paths 0), Script (scriptAt paths 1) Nothing (Just (ns 10000000)), noWait (scriptAt paths 2)]
        report ←
          alongside
            ( do
                -- The start table is written once every instance has initialized; the looped
                -- instance's interval is then armed on the fake timer.
                awaitOut fixture 5
                awaitLive fixture 1
                tickClock fixture 10000000
                fireLive fixture
                awaitRecorded fixture 2
                setStop fixture True
            )
            (run fixture runtime (config fixture scripts) >>= expectRan)
        reportEnding report `shouldBe` EndedStopRequest
        statusOf report `shouldBe` StatusInterrupted
        map (instanceEnd) (instancesOf report) `shouldSatisfy` \ends → case ends of
          [EndCompleted, EndStopped, EndStopped] → True
          _ → False
        found ← recorded fixture
        found `shouldContain` ["run"]
        found `shouldContain` ["update"]
        found `shouldContain` ["shutdown looped stopped"]
        found `shouldContain` ["shutdown event stopped"]

  describe "usage refused before any instance is admitted" $ do
    let refuse label scripts moduleFiles expected =
          it ("refuses " <> label) $ bounded $ do
            fixture ← newRFixture
            withScripts moduleFiles $ \paths →
              withBoundary $ \control runtime → do
                violations ← run fixture runtime (config fixture (scripts paths)) >>= expectRefused
                map violationReason violations `shouldBe` expected
                -- It names the script, when it names one, and no hook ran.
                forM_ violations $ \violation → violationScript violation `shouldSatisfy` maybe True (not . Text.null)
                recorded fixture >>= \found → filter (/= "loaded") found `shouldBe` []
                outLines fixture `shouldReturn` []
                errLines fixture `shouldReturn` []
                -- The VM that was started to ask is retired.
                outstanding control `shouldReturn` 0
    refuse
      "a module defining both run and update"
      (\paths → [Script (scriptAt paths 0) Nothing (Just (ns 5))])
      [("both.lua", lua ["fx.record('loaded')", "function run(self) fx.record('run') end", "function update(self, dt) fx.record('update') end"])]
      [ModuleDefinesRunAndUpdate]
    refuse
      "a module defining update with no interval"
      (\paths → [noWait (scriptAt paths 0)])
      [("update.lua", lua ["fx.record('loaded')", "function update(self, dt) fx.record('update') end"])]
      [UpdateNeedsInterval]
    refuse
      "an interval for a module that does not define update"
      (\paths → [Script (scriptAt paths 0) Nothing (Just (ns 5))])
      [("run.lua", lua ["fx.record('loaded')", "function run(self) fx.record('run') end"])]
      [IntervalWithoutUpdate]
    refuse
      "an interval for an event-only module"
      (\paths → [Script (scriptAt paths 0) Nothing (Just (ns 5))])
      [("event.lua", lua ["fx.record('loaded')"])]
      [IntervalWithoutUpdate]
    refuse
      "every script that is wrong, in script order"
      (\paths → [noWait (scriptAt paths 0), Script (scriptAt paths 1) Nothing (Just (ns 5)), noWait (scriptAt paths 2)])
      [ ("a.lua", lua ["function update(self, dt) end"])
      , ("b.lua", lua ["function run(self) end"])
      , ("c.lua", lua ["function run(self) end", "function update(self, dt) end"])
      ]
      [UpdateNeedsInterval, IntervalWithoutUpdate, ModuleDefinesRunAndUpdate]

  describe "usage that needs no VM" $ do
    it "refuses no scripts at all" $ bounded $ do
      fixture ← newRFixture
      withBoundary $ \control runtime → do
        violations ← run fixture runtime (config fixture []) >>= expectRefused
        map violationReason violations `shouldBe` [NoScripts]
        outstanding control `shouldReturn` 0
    it "refuses more scripts than a run admits, and admits exactly that many" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua eventOnly)] $ \paths → withBoundary $ \_ runtime → do
        let one = scriptAt paths 0
        violations ← run fixture runtime (config fixture (replicate (runnerMaxScripts + 1) (noWait one))) >>= expectRefused
        map violationReason violations `shouldBe` [TooManyScripts (runnerMaxScripts + 1) runnerMaxScripts]
        recorded fixture `shouldReturn` []
    it "refuses a zero interval and a zero limit" $ bounded $ do
      fixture ← newRFixture
      withScripts [("u.lua", lua looped)] $ \paths → withBoundary $ \_ runtime → do
        let scripts = [Script (scriptAt paths 0) Nothing (Just (ns 0))]
        violations ← run fixture runtime ((config fixture scripts) {runnerLimit = Just (ns 0)}) >>= expectRefused
        map violationReason violations `shouldBe` [LimitNotPositive, IntervalNotPositive]
        recorded fixture `shouldReturn` []
