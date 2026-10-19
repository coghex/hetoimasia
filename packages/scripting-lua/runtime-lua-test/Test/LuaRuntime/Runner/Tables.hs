-- | The TID/OWNER/NAME/STATUS tables, the barrier that opens the first, and the status value.
module Test.LuaRuntime.Runner.Tables (spec) where

import Control.Monad (forM_)
import Data.Char (isControl, isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Completed, Failed), InstanceSnapshot (snapshotPhase), ShutdownDisposition (ShutdownRan, ShutdownSkippedNoInit))
import Hetoimasia.Scripting.Lua.Runner
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotContain, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (bounded, withBoundary)

eventOnly ∷ Text → [Text]
eventOnly name = ["function shutdown(self, reason) fx.record('shutdown " <> name <> " ' .. reason) end"]

-- | Wait until an instance has failed.
awaitFailed ∷ RFixture → IO ()
awaitFailed fixture = awaitSnapshots fixture (any ((== Failed) . snapshotPhase))

-- | The table the run writes: the title, then the rows, for these instances and statuses.
tableFor ∷ Text → RunReport → [(Text, Text)] → [Text]
tableFor title report rows =
  title
    : tableLines
      [ TableRow (tidText (instanceTid item)) "vm" name status
      | (item, (name, status)) ← zip (instancesOf report) rows
      ]

spec ∷ Spec
spec = describe "tables and status" $ do
  it "writes the start table once every instance has initialized and the end table once the VM is retired, to the output sink only" $ bounded $ do
    fixture ← newRFixture
    withScripts [("alpha.lua", lua (eventOnly "alpha")), ("beta.lua", lua ["function run(self) fx.block('beta') end"])] $ \paths →
      withBoundary $ \_ runtime → do
        report ←
          alongside
            ( awaitGate fixture "beta"
                -- The owner is held in beta's run: both instances have initialized, and the table is written.
                >> awaitOut fixture 4
                >> openGate fixture "beta"
                >> awaitSnapshots fixture (any ((== Completed) . snapshotPhase))
                >> setStop fixture True
            )
            (run fixture runtime (config fixture [Script (scriptAt paths 0) (Just "alpha") Nothing, Script (scriptAt paths 1) (Just "beta") Nothing]) >>= expectRan)
        reportEnding report `shouldBe` EndedStopRequest
        out ← outLines fixture
        out
          `shouldBe` tableFor startTitle report [("alpha", "active"), ("beta", "active")]
            <> tableFor endTitle report [("alpha", "stopped"), ("beta", "completed")]
        errLines fixture `shouldReturn` []
        -- A TID is its three numbers, dotted.
        forM_ (tidsOf report) $ \tid → map (Text.all isDigit) (Text.splitOn "." (tidText tid)) `shouldBe` [True, True, True]

  it "lists the instance that was not begun when the run is stopped, as stopped without its init, and writes no start table" $ bounded $ do
    fixture ← newRFixture
    withScripts
      [ ("a.lua", lua (["function init(self) fx.block('a') end"] <> eventOnly "a"))
      , ("b.lua", lua (["function init(self) fx.record('b init') end"] <> eventOnly "b"))
      ]
      $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside
              -- The owner is held in a's init and b is admitted behind it, not begun. The stop request is
              -- noticed, the run asks its owner to retire, and only then is the initializer let go.
              (awaitGate fixture "a" >> setStop fixture True >> awaitRetiring fixture 1 >> openGate fixture "a")
              (runTick fixture runtime (config fixture (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          -- The stop did not wait for b's initializer, and did not make it run to satisfy a barrier.
          recorded fixture `shouldReturn` ["shutdown a stopped"]
          map instanceShutdown (instancesOf report) `shouldBe` [ShutdownRan, ShutdownSkippedNoInit]
          out ← outLines fixture
          out `shouldNotContain` [startTitle]
          out `shouldBe` tableFor endTitle report [("a.lua", "stopped"), ("b.lua", "stopped")]

  it "writes the start table when the held initializer is let go, with both instances active" $ bounded $ do
    -- One init holds the owner while the next instance waits behind it: the barrier opens when both have finished.
    fixture ← newRFixture
    withScripts
      [ ("a.lua", lua (["function init(self) fx.block('a') end"] <> eventOnly "a"))
      , ("b.lua", lua (["function init(self) fx.record('b init') end"] <> eventOnly "b"))
      ]
      $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside
              (awaitGate fixture "a" >> openGate fixture "a" >> awaitOut fixture 4 >> setStop fixture True)
              (run fixture runtime (config fixture (map noWait paths)) >>= expectRan)
          out ← outLines fixture
          take 4 out `shouldBe` tableFor startTitle report [("a.lua", "active"), ("b.lua", "active")]

  it "writes no table for a run that admitted no instance" $ bounded $ do
    fixture ← newRFixture
    withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
      withBoundary $ \_ runtime → do
        setStop fixture True
        _ ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
        outLines fixture `shouldReturn` []

  describe "are bounded" $ do
    it "admits as many scripts as the live bound, and a table of them has that many rows" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside (awaitOut fixture (runnerMaxScripts + 2) >> setStop fixture True) $
              run fixture runtime (config fixture (replicate runnerMaxScripts (noWait (scriptAt paths 0)))) >>= expectRan
          length (instancesOf report) `shouldBe` runnerMaxScripts
          out ← outLines fixture
          length (takeWhile (/= endTitle) out) `shouldBe` runnerMaxScripts + 2

    it "cuts the owner and name cells with a visible marker and replaces control characters" $ bounded $ do
      fixture ← newRFixture
      withScripts [("e.lua", lua (eventOnly "e"))] $ \paths →
        withBoundary $ \_ runtime → do
          let long = Text.replicate 100 "n"
              scripts = [Script (scriptAt paths 0) (Just long) Nothing, Script (scriptAt paths 0) (Just "evil\nname\ESC[0m\tx") Nothing]
              configured = (config fixture scripts) {runnerName = Text.replicate 80 "v"}
          report ← alongside (awaitOut fixture 4 >> setStop fixture True) (run fixture runtime configured >>= expectRan)
          out ← outLines fixture
          forM_ out $ \line → Text.any isControl line `shouldBe` False
          -- Every cell of the owner and name columns is at most the column limit, and a cut ends in the marker.
          let rows = drop 2 (takeWhile (/= endTitle) out)
          length rows `shouldBe` 2
          forM_ rows $ \row → do
            let cells = filter (not . Text.null) (Text.splitOn "  " row)
            forM_ (take 2 (drop 1 cells)) $ \cell → Text.length (Text.strip cell) `shouldSatisfy` (<= columnLimit)
          out `shouldSatisfy` any (Text.isInfixOf (Text.replicate (columnLimit - Text.length truncationMarker) "v" <> truncationMarker))
          out `shouldSatisfy` any (Text.isInfixOf "evil\\x0aname\\x1b[0m\\x09x")
          length (instancesOf report) `shouldBe` 2

  describe "the status value" $ do
    let failingOne = ("fail.lua", lua ["function run(self) error('boom') end"])
        completing = ("done.lua", lua ["function run(self) fx.record('done') end"])
        waiting = ("e.lua", lua (eventOnly "e"))
        statusOfRun label files configure drive expected =
          it label $ bounded $ do
            fixture ← newRFixture
            withScripts files $ \paths →
              withBoundary $ \_ runtime → do
                report ← alongside (drive fixture) (run fixture runtime (configure fixture (map noWait paths)) >>= expectRan)
                statusOf report `shouldBe` expected
    statusOfRun "is success when every instance completes" [completing] (\f s → config f s) (\_ → pure ()) StatusSuccess
    statusOfRun "is success when the limit ends the run" [waiting] (\f s → (config f s) {runnerLimit = Just (ns 1000000)}) (\f → awaitOut f 3 >> awaitLive f 1 >> tickClock f 1000000 >> fireLive f) StatusSuccess
    statusOfRun "is interrupted when the stop request ends the run and nothing failed" [waiting] (\f s → config f s) (\f → awaitOut f 3 >> setStop f True) StatusInterrupted
    statusOfRun "is failure when an instance failed" [failingOne] (\f s → config f s) (\_ → pure ()) StatusFailure
    statusOfRun "is failure when an instance failed and the stop request ended the run" [failingOne, waiting] (\f s → config f s) (\f → awaitOut f 3 >> awaitFailed f >> setStop f True) StatusFailure
    statusOfRun "is failure when an instance failed and the limit ended the run" [failingOne, waiting] (\f s → (config f s) {runnerLimit = Just (ns 1000000)}) (\f → awaitOut f 3 >> awaitFailed f >> awaitLive f 1 >> tickClock f 1000000 >> fireLive f) StatusFailure
    statusOfRun "is success when a Lua control stopped an instance and the others completed" [("stop.lua", lua ["function init(self) lifecycle.stop(lifecycle.self()) end"]), completing] (\f s → config f s) (\_ → pure ()) StatusSuccess
    it "follows a failure, then a stop request, then success, for every ending" $
      forM_ [(failed, ending) | failed ← [False, True], ending ← [EndedAllInstances, EndedLimit, EndedStopRequest, EndedStartupFailure]] $ \(failed, ending) →
        runStatusOf failed ending
          `shouldBe` if failed || ending == EndedStartupFailure then StatusFailure else if ending == EndedStopRequest then StatusInterrupted else StatusSuccess
