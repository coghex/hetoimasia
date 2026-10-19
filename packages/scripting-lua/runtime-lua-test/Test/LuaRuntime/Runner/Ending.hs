-- | How a run ends, and what ends it: every instance having ended, a Lua control, the limit, the stop
-- request, and the order in which several that apply together are decided.
module Test.LuaRuntime.Runner.Ending (spec) where

import Control.Monad (forM_)
import Hetoimasia.Foundation.Time (maximumDuration)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Completed, Paused), InstanceSnapshot (snapshotPhase), isTerminal)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Runner
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Scheduler.Support (fireReg)
import Test.LuaRuntime.Support (bounded, withBoundary)

-- | Reports an instance by its shutdown, so the order of shutdowns is read from what was recorded.
shutdownOf ∷ Text → [Text]
shutdownOf name = ["function shutdown(self, reason) fx.record('shutdown " <> name <> " ' .. reason) end"]

eventOnly ∷ Text → [Text]
eventOnly = shutdownOf

endsOf ∷ RunReport → [InstanceEnd]
endsOf = map instanceEnd . instancesOf

isCompleted, isStopped ∷ InstanceEnd → Bool
isCompleted = \case EndCompleted → True; _ → False
isStopped = \case EndStopped → True; _ → False

shutdowns ∷ RFixture → IO [Text]
shutdowns fixture = filter (Text.isPrefixOf "shutdown") <$> recorded fixture

spec ∷ Spec
spec = describe "how a run ends" $ do
  describe "by itself" $ do
    it "ends when a one-shot completes, and retires the VM" $ bounded $ do
      fixture ← newRFixture
      withScripts [("one.lua", lua ["function run(self) fx.record('ran') print('hello', 7) end"])] $ \paths →
        withBoundary $ \control runtime → do
          report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          statusOf report `shouldBe` StatusSuccess
          recorded fixture `shouldReturn` ["ran"]
          outLines fixture >>= (`shouldSatisfy` elem "hello\t7")
          errLines fixture `shouldReturn` []
          map instanceStatus (instancesOf report) `shouldBe` [Completed]
          outstanding control `shouldReturn` 0

    it "ends when a script stops itself" $ bounded $ do
      fixture ← newRFixture
      withScripts [("self.lua", lua (["function init(self) lifecycle.stop(lifecycle.self()) end"] <> eventOnly "self"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          statusOf report `shouldBe` StatusSuccess
          map isStopped (endsOf report) `shouldBe` [True]
          shutdowns fixture `shouldReturn` ["shutdown self stopped"]

    it "ends when a script stops another" $ bounded $ do
      fixture ← newRFixture
      let stopper =
            [ "function run(self)"
            , "  local me = lifecycle.owners().owners[1]"
            , "  local seen = lifecycle.inspect_owner({runtime = me.runtime, owner = me.owner})"
            , "  for _, snapshot in ipairs(seen.instances) do"
            , "    if snapshot.name == 'target' then fx.record('stopping target'); lifecycle.stop(snapshot.tid) end"
            , "  end"
            , "end"
            ]
      withScripts [("target.lua", lua (eventOnly "target")), ("stopper.lua", lua stopper)] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (config fixture [Script (scriptAt paths 0) (Just "target") Nothing, noWait (scriptAt paths 1)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          statusOf report `shouldBe` StatusSuccess
          fmap isStopped (take 1 (endsOf report)) `shouldBe` [True]
          fmap isCompleted (drop 1 (endsOf report)) `shouldBe` [True]
          shutdowns fixture `shouldReturn` ["shutdown target stopped"]

    it "does not end while an instance is paused, and the stop request ends it" $ bounded $ do
      fixture ← newRFixture
      withScripts [("paused.lua", lua (["function init(self) lifecycle.pause(lifecycle.self()) end"] <> eventOnly "paused"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside
              (awaitOut fixture 3 >> awaitSnapshots fixture (any ((== Paused) . snapshotPhase)) >> setStop fixture True)
              (run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          shutdowns fixture `shouldReturn` ["shutdown paused stopped"]

  describe "by the stop request" $ do
    it "ends the run, stops the instance in order and retires the VM" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \control runtime → do
          report ←
            alongside (awaitOut fixture 3 >> setStop fixture True) $
              run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedStopRequest
          statusOf report `shouldBe` StatusInterrupted
          map isStopped (endsOf report) `shouldBe` [True]
          shutdowns fixture `shouldReturn` ["shutdown e stopped"]
          outstanding control `shouldReturn` 0
          liveCount fixture `shouldReturn` 0

    it "admits nothing and starts nothing when it is already set before the run" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (["fx.record('loaded')"] <> eventOnly "e"))] $ \paths →
        withBoundary $ \control runtime → do
          setStop fixture True
          report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedStopRequest
          statusOf report `shouldBe` StatusInterrupted
          instancesOf report `shouldBe` []
          recorded fixture `shouldReturn` []
          outLines fixture `shouldReturn` []
          errLines fixture `shouldReturn` []
          outstanding control `shouldReturn` 0

    it "lets a running segment return: the instance in the middle of its run completes" $ bounded $ do
      fixture ← newRFixture
      withScripts [("slow.lua", lua ["function run(self) fx.block('hold') fx.record('finished') end", "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            -- The stop request is set while the segment is held, and the segment is let go once the run has
            -- asked its owner to retire.
            alongside (awaitGate fixture "hold" >> setStop fixture True >> awaitRetiring fixture 0 >> openGate fixture "hold") $
              runTick fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
          -- The stop request was set while the segment was held, and the segment was not cut short.
          reportEnding report `shouldBe` EndedStopRequest
          recorded fixture >>= (`shouldContain` ["finished"])

  describe "by the limit" $ do
    let limited fixture scripts = (config fixture scripts) {runnerLimit = Just (ns 1000000)}
    it "ends the run on the fake timer when the clock reaches it, as a success" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \control runtime → do
          report ←
            alongside (awaitOut fixture 3 >> awaitLive fixture 1 >> tickClock fixture 1000000 >> fireLive fixture) $
              run fixture runtime (limited fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedLimit
          statusOf report `shouldBe` StatusSuccess
          shutdowns fixture `shouldReturn` ["shutdown e stopped"]
          outstanding control `shouldReturn` 0
          liveCount fixture `shouldReturn` 0

    it "measures the limit from the instant the run began, whatever the clock read before" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          tickClock fixture 5000000
          report ←
            alongside
              ( awaitOut fixture 3
                  >> awaitLive fixture 1
                  -- Not yet: a limit of one millisecond after the origin is 6ms on the clock.
                  >> tickClock fixture 999999
                  >> fireLive fixture
                  >> awaitCount (regCount fixture) 2
                  >> awaitLive fixture 1
                  >> tickClock fixture 1
                  >> fireLive fixture
              )
              (run fixture runtime (limited fixture [noWait (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedLimit
          -- The early wake found the deadline not reached and the run armed again.
          regCount fixture `shouldReturn` 2

    it "ignores a wake of a registration that was replaced" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside
              ( awaitOut fixture 3
                  >> awaitLive fixture 1
                  >> (liveTimers fixture >>= \firsts → mapM_ fireReg firsts >> awaitCount (regCount fixture) 2 >> awaitLive fixture 1 >> mapM_ fireReg firsts)
                  >> tickClock fixture 1000000
                  >> fireLive fixture
              )
              (run fixture runtime (limited fixture [noWait (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedLimit
          liveCount fixture `shouldReturn` 0

    it "cancels the timer's registration when every instance ends first" $ bounded $ do
      fixture ← newRFixture
      withScripts [("one.lua", lua ["function run(self) fx.record('ran') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (limited fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          regCount fixture >>= (`shouldSatisfy` (>= 1))
          liveCount fixture `shouldReturn` 0

    it "cancels the timer's registration when the stop request ends the run" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitOut fixture 3 >> awaitLive fixture 1 >> setStop fixture True) $
              run fixture runtime (limited fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedStopRequest
          liveCount fixture `shouldReturn` 0

    it "never reaches a limit the clock cannot represent" $ bounded $ do
      fixture ← newRFixture
      withScripts [("one.lua", lua ["function run(self) fx.record('ran') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          tickClock fixture 1
          report ← run fixture runtime ((config fixture [noWait (scriptAt paths 0)]) {runnerLimit = Just maximumDuration}) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          regCount fixture `shouldReturn` 0

  describe "when several endings apply together" $ do
    -- The run's own thread is held while the start table is written, so everything that can end the run
    -- is ready by the time it next waits. The order of precedence is the contract.
    let held fixture scripts = gatedOn fixture startTitle "table" ((config fixture scripts) {runnerLimit = Just (ns 1000000)})
        everythingReady fixture = awaitGate fixture "table" >> setStop fixture True >> tickClock fixture 1000000 >> fireLive fixture >> openGate fixture "table"
    it "ends as every instance having ended when that and the stop request and the limit all apply" $ bounded $ do
      fixture ← newRFixture
      withScripts [("one.lua", lua ["function run(self) fx.record('ran') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitGate fixture "table" >> awaitSnapshots fixture (all (isTerminal . snapshotPhase)) >> everythingReady' fixture) $
              run fixture runtime (held fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          -- The stop request was set, and the run was not interrupted by it: nothing was left to stop.
          map isCompleted (endsOf report) `shouldBe` [True]
    it "ends as the stop request when it and the limit both apply, and so is interrupted" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (everythingReady fixture) $
              run fixture runtime (held fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedStopRequest
          statusOf report `shouldBe` StatusInterrupted
          liveCount fixture `shouldReturn` 0
    it "ends as the limit when only the limit applies" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitGate fixture "table" >> tickClock fixture 1000000 >> fireLive fixture >> openGate fixture "table") $
              run fixture runtime (held fixture [noWait (scriptAt paths 0)]) >>= expectRan
          reportEnding report `shouldBe` EndedLimit
          statusOf report `shouldBe` StatusSuccess

  describe "every remaining instance is stopped in ascending TID order, once, with reason stopped" $ do
    let scripts paths =
          [ noWait (scriptAt paths 0)
          , Script (scriptAt paths 1) Nothing (Just (ns 10000000))
          , noWait (scriptAt paths 2)
          ]
        files =
          [ ("e.lua", lua (eventOnly "e"))
          , ("l.lua", lua (["function update(self, dt) fx.record('update') end"] <> shutdownOf "l"))
          , ("p.lua", lua (["function init(self) lifecycle.pause(lifecycle.self()) end"] <> shutdownOf "p"))
          ]
        paused = awaitSnapshots
        expected = ["shutdown e stopped", "shutdown l stopped", "shutdown p stopped"]
    forM_ [("the stop request", False), ("the limit", True)] $ \(label, byLimit) →
      it ("on " <> label <> ", with event-only, looped and paused instances live") $ bounded $ do
        fixture ← newRFixture
        withScripts files $ \paths →
          withBoundary $ \_ runtime → do
            let configured = (config fixture (scripts paths)) {runnerLimit = if byLimit then Just (ns 1000000) else Nothing}
            report ←
              alongside
                ( awaitOut fixture 5
                    >> paused fixture (any (\snapshot → snapshotPhase snapshot == Paused))
                    >> if byLimit then tickClock fixture 1000000 >> fireLive fixture else setStop fixture True
                )
                (run fixture runtime configured >>= expectRan)
            reportEnding report `shouldBe` (if byLimit then EndedLimit else EndedStopRequest)
            shutdowns fixture `shouldReturn` expected
            map isStopped (endsOf report) `shouldBe` [True, True, True]

-- | Everything that can end the run, made ready while the run's thread is held at the gate, then the gate opened.
everythingReady' ∷ RFixture → IO ()
everythingReady' fixture = setStop fixture True >> tickClock fixture 1000000 >> fireLive fixture >> openGate fixture "table"
