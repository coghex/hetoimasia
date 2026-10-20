-- | The tick clock: what it refuses, the driver that grants ticks, the tick limit, how a run on ticks
-- ends, and the Lua controls the runner places on it.
module Test.LuaRuntime.Runner.Ticks (spec) where

import Control.Concurrent (yield)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM_, replicateM_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (maximumDuration)
import Hetoimasia.Scripting.Lua.Instance (InstanceId (instanceLocal), ShutdownDisposition (ShutdownRan))
import Hetoimasia.Scripting.Lua.Runner
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (Gated (..), bounded, brokenIs, expectFatal, withBoundary, withBoundaryOpening)

period ∷ Word64
period = 1000

-- | A looped instance that notes each update with its delta, and what it is stopped with.
counting ∷ Text → [Text]
counting name =
  [ "function update(self, dt) fx.record('" <> name <> " ' .. string.format('%.9f', dt)) end"
  , "function shutdown(self, reason) fx.record('shutdown " <> name <> " ' .. reason) end"
  ]

eventOnly ∷ Text → [Text]
eventOnly name = ["function shutdown(self, reason) fx.record('shutdown " <> name <> " ' .. reason) end"]

-- | A looped instance whose first update waits at this gate.
blockingFirst ∷ Text → Text → [Text]
blockingFirst gate name =
  [ "function update(self, dt)"
  , "  fx.record('" <> name <> " update')"
  , "  if fx.bump() == 1 then fx.block('" <> gate <> "') end"
  , "end"
  , "function shutdown(self, reason) fx.record('shutdown " <> name <> " ' .. reason) end"
  ]

everyTick ∷ FilePath → Script
everyTick = everyTicks 1 . script

spec ∷ Spec
spec = describe "ticks" $ do
  describe "what the tick clock refuses before anything is admitted" $ do
    let refuse label build expected = it label $ bounded $ do
          fixture ← newRFixture
          withBoundary $ \_ runtime → do
            violations ← run fixture runtime (build fixture) >>= expectRefused
            violations `shouldBe` expected
            -- Before any admission or hook: no VM was started to hold a registration.
            regCount fixture `shouldReturn` 0
            recorded fixture `shouldReturn` []
        loop = Script "x.lua" Nothing
        tickVm fixture scripts = (config fixture scripts) {runnerTick = Just (ns period)}
        limited fixture n = (tickVm fixture [script "x.lua"]) {runnerTickLimit = Just n}
    refuse "a tick duration of zero" (\fixture → (config fixture [script "x.lua"]) {runnerTick = Just (ns 0)}) [UsageViolation Nothing TickDurationNotPositive]
    refuse "an elapsed interval on a tick VM" (\fixture → tickVm fixture [loop (Just (ns 5))]) [UsageViolation (Just "x.lua") ElapsedIntervalOnTickClock]
    refuse "a tick interval on an elapsed VM" (\fixture → config fixture [everyTicks 3 (script "x.lua")]) [UsageViolation (Just "x.lua") TickIntervalOnElapsedClock]
    refuse "a tick limit without a tick duration" (\fixture → (config fixture [script "x.lua"]) {runnerTickLimit = Just 3}) [UsageViolation Nothing TickLimitNeedsTickClock]
    refuse "a tick limit of zero" (\fixture → limited fixture 0) [UsageViolation Nothing TickCountNotPositive]
    refuse "a negative tick limit" (\fixture → limited fixture (-4)) [UsageViolation Nothing TickCountNotPositive]
    refuse "a tick limit that does not fit a 64-bit tick" (\fixture → limited fixture (toInteger (maxBound ∷ Word64) + 1)) [UsageViolation Nothing TickCountTooLarge]
    refuse "a tick interval of zero" (\fixture → tickVm fixture [everyTicks 0 (script "x.lua")]) [UsageViolation (Just "x.lua") TickCountNotPositive]
    refuse "a negative tick interval" (\fixture → tickVm fixture [everyTicks (-1) (script "x.lua")]) [UsageViolation (Just "x.lua") TickCountNotPositive]
    refuse "a tick interval that does not fit a 64-bit tick" (\fixture → tickVm fixture [everyTicks (toInteger (maxBound ∷ Word64) + 1) (script "x.lua")]) [UsageViolation (Just "x.lua") TickCountTooLarge]
    refuse
      "every reason together, the VM's before the scripts', each script's in script order"
      (\fixture → (tickVm fixture [loop (Just (ns 5)), everyTicks 0 (script "y.lua")]) {runnerTickLimit = Just 0})
      [ UsageViolation Nothing TickCountNotPositive
      , UsageViolation (Just "x.lua") ElapsedIntervalOnTickClock
      , UsageViolation (Just "y.lua") TickCountNotPositive
      ]
    it "accepts the largest tick count there is, as a limit and as an interval" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua (counting "l"))] $ \paths →
        withBoundary $ \_ runtime → do
          let largest = toInteger (maxBound ∷ Word64)
          report ←
            alongside fixture
              (driveTicks fixture period 1 >> setStop fixture True)
              (run fixture runtime ((tickConfig fixture period (Just largest) [everyTicks largest (script (scriptAt paths 0))])) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest

  describe "the driver" $ do
    it "grants ticks of exactly the tick duration, one for each tick that is due" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua (counting "l"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture period 3)
              (run fixture runtime (tickConfig fixture period (Just 3) [everyTick (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          reportTicks report `shouldBe` 3
          recorded fixture
            >>= ( `shouldBe`
                    [ "l 0.000001000"
                    , "l 0.000001000"
                    , "l 0.000001000"
                    , "shutdown l stopped"
                    ]
                )
          liveCount fixture `shouldReturn` 0

    it "grants back-to-back ticks when the clock jumps past several deadlines while a segment is held, with none skipped, merged or shortened" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua (blockingFirst "seg" "l"))] $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              ( awaitLive fixture 1
                  >> tickClock fixture period
                  >> fireLive fixture
                  >> awaitGate fixture "seg"
                  -- Five deadlines pass while the first tick's segment is held: the other four are due at once.
                  >> tickClock fixture (5 * period)
                  >> openGate fixture "seg"
              )
              (run fixture runtime (tickConfig fixture period (Just 6) [everyTick (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          reportTicks report `shouldBe` 6
          -- One update for each tick: the number granted is the number due.
          recorded fixture >>= \seen → length (filter (== "l update") seen) `shouldBe` 6
          liveCount fixture `shouldReturn` 0

    it "grants nothing for an early wake, nor for a stale one" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua (counting "l"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              ( do
                  awaitLive fixture 1
                  -- The timer fires with the clock short of the deadline: an early wake.
                  before ← regCount fixture
                  tickClock fixture (period - 1)
                  fireLive fixture
                  awaitCount (regCount fixture) (before + 1)
                  awaitLive fixture 1
                  recorded fixture `shouldReturn` []
                  -- A registration that is no longer live fires, as a timer that was cancelled too late would.
                  fireEvery fixture
                  recorded fixture `shouldReturn` []
                  -- One nanosecond more, and a tick is due.
                  tickClock fixture 1
                  fireLive fixture
              )
              (run fixture runtime (tickConfig fixture period (Just 1) [everyTick (scriptAt paths 0)]) >>= expectRan)
          reportTicks report `shouldBe` 1
          recorded fixture >>= \seen → length (filter (== "l 0.000001000") seen) `shouldBe` 1

    it "grants no further tick once a stop begins, and counts the tick that was in progress as not completed" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua (blockingFirst "seg" "l"))] $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              ( awaitLive fixture 1
                  >> tickClock fixture (3 * period)
                  >> fireLive fixture
                  >> awaitGate fixture "seg"
                  >> setStop fixture True
                  >> openGate fixture "seg"
              )
              (run fixture runtime (tickConfig fixture period Nothing [everyTick (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          -- The segment returned, three ticks were due, and only the one in progress was ever granted.
          recorded fixture >>= (`shouldBe` ["l update", "shutdown l stopped"])
          reportTicks report `shouldBe` 0
          liveCount fixture `shouldReturn` 0

  describe "the tick limit" $ do
    it "ends the run after exactly the number of ticks it names, and stops what is left, in order, with the reason stopped" $ bounded $ do
      fixture ← newRFixture
      withScripts
        [ ("ev.lua", lua (eventOnly "ev"))
        , ("loop.lua", lua (counting "loop"))
        , ("paused.lua", lua (["function init(self) lifecycle.pause(lifecycle.self()) end"] <> eventOnly "paused"))
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ←
              alongside fixture
                (driveTicks fixture period 2)
                (run fixture runtime (tickConfig fixture period (Just 2) [script (scriptAt paths 0), everyTick (scriptAt paths 1), script (scriptAt paths 2)]) >>= expectRan)
            reportEnding report `shouldBe` EndedTickLimit
            reportTicks report `shouldBe` 2
            recorded fixture
              >>= ( `shouldBe`
                      [ "loop 0.000001000"
                      , "loop 0.000001000"
                      , "shutdown ev stopped"
                      , "shutdown loop stopped"
                      , "shutdown paused stopped"
                      ]
                  )
            statusOf report `shouldBe` StatusSuccess

    it "is a failure when an instance failed" $ bounded $ do
      fixture ← newRFixture
      withScripts [("bad.lua", lua ["function update(self, dt) error('boom') end"]), ("ok.lua", lua (counting "ok"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture period 2)
              (run fixture runtime (tickConfig fixture period (Just 2) (map everyTick paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          statusOf report `shouldBe` StatusFailure
          map (maybe False (const True) . failureOf) (instancesOf report) `shouldBe` [True, False]

    it "is a failure when only a shutdown failed" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua ["function update(self, dt) end", "function shutdown(self, reason) error('late') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture period 2)
              (run fixture runtime (tickConfig fixture period (Just 2) [everyTick (scriptAt paths 0)]) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          statusOf report `shouldBe` StatusFailure

  describe "how a run on ticks ends" $ do
    let threeLive =
          [ ("ev.lua", lua (eventOnly "ev"))
          , ("loop.lua", lua (counting "loop"))
          , ("paused.lua", lua (["function init(self) lifecycle.pause(lifecycle.self()) end"] <> eventOnly "paused"))
          ]
        threeScripts paths = [script (scriptAt paths 0), everyTick (scriptAt paths 1), script (scriptAt paths 2)]
        stoppedInOrder seen = filter (Text.isPrefixOf "shutdown") seen `shouldBe` ["shutdown ev stopped", "shutdown loop stopped", "shutdown paused stopped"]
    it "stops every instance left, once, in ascending TID order, whichever limit or request ended the run" $ bounded $ do
      forM_ (["the tick limit", "the duration limit", "the stop request", "a duration limit that arrives mid-tick"] ∷ [String]) $ \label → do
        fixture ← newRFixture
        let blocking = [("ev.lua", lua (eventOnly "ev")), ("loop.lua", lua (blockingFirst "seg" "loop")), ("paused.lua", lua (["function init(self) lifecycle.pause(lifecycle.self()) end"] <> eventOnly "paused"))]
            files = if label == "a duration limit that arrives mid-tick" then blocking else threeLive
            limits = if label `elem` ["the duration limit", "a duration limit that arrives mid-tick"] then Just (ns (period + period `div` 2)) else Nothing
            tickLimit = if label == "the tick limit" then Just 1 else Nothing
        withScripts files $ \paths →
          withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
            let driver = case label of
                  "the tick limit" → driveTicks fixture period 1
                  "the duration limit" → driveTicks fixture period 1 >> awaitLive fixture 2 >> tickClock fixture (period `div` 2 + 1) >> fireLive fixture
                  "the stop request" → driveTicks fixture period 1 >> awaitLive fixture 1 >> setStop fixture True
                  _ → awaitLive fixture 2 >> tickClock fixture period >> fireLive fixture >> awaitGate fixture "seg" >> tickClock fixture period >> fireLive fixture
                finish = if label == "a duration limit that arrives mid-tick" then openGate fixture "seg" else pure ()
            report ←
              alongside fixture (driver >> finish) $
                run fixture runtime ((tickConfig fixture period tickLimit (threeScripts paths)) {runnerLimit = limits}) >>= expectRan
            reportEnding report
              `shouldBe` ( case label of
                             "the tick limit" → EndedTickLimit
                             "the stop request" → EndedStopRequest
                             _ → EndedLimit
                         )
            recorded fixture >>= stoppedInOrder
            map instanceShutdown (instancesOf report) `shouldBe` replicate 3 ShutdownRan
            liveCount fixture `shouldReturn` 0

    describe "when several endings hold together at a tick's boundary" $ do
      -- The run's own thread is held in the write of a failure report while the tick finishes, so that
      -- what can end the run is ready by the time it next waits. The order of precedence is the contract:
      -- every instance having ended, the stop request, the tick limit, the duration limit.
      let failing = ("bad.lua", lua ["function update(self, dt) error('boom') end"])
          blocker = ("blk.lua", lua (blockingFirst "seg" "blk"))
          held fixture scripts tickLimit extra =
            gatedErrorsOn fixture "failure:" "rep" ((tickConfig fixture period tickLimit scripts) {runnerLimit = extra})
          tie label scriptsOf expectedEnding setup = it label $ bounded $ do
            fixture ← newRFixture
            withScripts scriptsOf $ \paths →
              withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
                report ←
                  alongside fixture
                    (awaitLive fixture (maybe 1 (const 2) (limitFor label)) >> tickClock fixture period >> fireLive fixture >> awaitGate fixture "rep" >> setup fixture)
                    (run fixture runtime (held fixture (map everyTick paths) (tickLimitFor label) (limitFor label)) >>= expectRan)
                reportEnding report `shouldBe` expectedEnding
                liveCount fixture `shouldReturn` 0
          tickLimitFor label = if "tick limit" `Text.isInfixOf` Text.pack label then Just 1 else Nothing
          limitFor label = if "duration limit" `Text.isInfixOf` Text.pack label then Just (ns (2 * period)) else Nothing
          letTickFinish fixture = openGate fixture "seg" >> awaitIdle fixture >> openGate fixture "rep"
      tie "the tick limit beats the duration limit" [failing, blocker] EndedTickLimit $ \fixture →
        tickClock fixture (3 * period) >> fireLive fixture >> letTickFinish fixture
      tie "the stop request beats the tick limit, though the tick finished" [failing, blocker] EndedStopRequest $ \fixture →
        setStop fixture True >> letTickFinish fixture
      tie "the stop request beats the duration limit" [failing, blocker] EndedStopRequest $ \fixture →
        setStop fixture True >> tickClock fixture (3 * period) >> fireLive fixture >> letTickFinish fixture
      tie "every instance having ended beats the stop request, and the tick limit, and the duration limit" [failing] EndedAllInstances $ \fixture →
        setStop fixture True >> tickClock fixture (3 * period) >> fireLive fixture >> openGate fixture "rep"

  describe "Lua controls on a tick VM" $ do
    let tidOf =
          [ "local function tid_of(name)"
          , "  local me = lifecycle.owners().owners[1]"
          , "  local seen = lifecycle.inspect_owner({runtime = me.runtime, owner = me.owner})"
          , "  for _, snapshot in ipairs(seen.instances) do"
          , "    if snapshot.name == name then return snapshot.tid end"
          , "  end"
          , "end"
          ]
        -- A looped instance that, at its first update, issues these controls in this order.
        issuing label controls =
          tidOf
            <> [ "local done = false"
               , "function update(self, dt)"
               , "  if done then return end"
               , "  done = true"
               ]
            <> [ "  local r" <> Text.pack (show i) <> " = lifecycle." <> verb <> "(tid_of('" <> target <> ".lua'))"
               | (i, (verb, target)) ← zip [1 ∷ Int ..] controls
               ]
            <> [ "  fx.record('" <> label <> " ' .. " <> Text.intercalate " .. ' ' .. " ["tostring(r" <> Text.pack (show i) <> ".accepted)" | i ← [1 .. length controls]] <> ")"
               , "end"
               ]
    it "places the controls several instances issue in one tick in the order they were issued, each in a place of its own, and refuses none" $ bounded $ do
      fixture ← newRFixture
      withScripts
        [ ("x.lua", lua (eventOnly "x"))
        , ("y.lua", lua (eventOnly "y"))
        , ("z.lua", lua (eventOnly "z"))
        , ("a.lua", lua (issuing "a" [("stop", "z")]))
        , ("b.lua", lua (issuing "b" [("stop", "y")]))
        , ("c.lua", lua (issuing "c" [("stop", "x")]))
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ←
              alongside fixture
                (driveTicks fixture period 2)
                (run fixture runtime (tickConfig fixture period (Just 2) (script (scriptAt paths 0) : script (scriptAt paths 1) : script (scriptAt paths 2) : map everyTick (drop 3 paths))) >>= expectRan)
            reportEnding report `shouldBe` EndedTickLimit
            -- Issued in one tick by three instances, in the order the owner ran them; applied at the next tick
            -- in that order, and none answered late or duplicate.
            recorded fixture
              >>= ( `shouldBe`
                      [ "a true"
                      , "b true"
                      , "c true"
                      , "shutdown z stopped"
                      , "shutdown y stopped"
                      , "shutdown x stopped"
                      ]
                  )

    it "places several controls one instance issues in one tick in the order it issued them" $ bounded $ do
      fixture ← newRFixture
      withScripts
        [ ("a.lua", lua (eventOnly "a"))
        , ("b.lua", lua (eventOnly "b"))
        , ("c.lua", lua (eventOnly "c"))
        , ("ctl.lua", lua (issuing "ctl" [("stop", "c"), ("stop", "a"), ("pause", "b"), ("resume", "b")]))
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ←
              alongside fixture
                (driveTicks fixture period 3)
                (run fixture runtime (tickConfig fixture period (Just 3) (map script (take 3 paths) <> [everyTick (scriptAt paths 3)])) >>= expectRan)
            reportEnding report `shouldBe` EndedTickLimit
            -- A control affects its target and nothing more: the run goes on after the stops, to its tick limit,
            -- the stops scripts directed keep their own order, and the sweep stops what is left.
            recorded fixture
              >>= ( `shouldBe`
                      [ "ctl true true true true"
                      , "shutdown c stopped"
                      , "shutdown a stopped"
                      , "shutdown b stopped"
                      ]
                  )
            reportTicks report `shouldBe` 3

    it "ends the run only by every instance having ended when scripts stop each other and themselves" $ bounded $ do
      fixture ← newRFixture
      withScripts
        [ ("a.lua", lua (eventOnly "a"))
        , ("ctl.lua", lua (issuing "ctl" [("stop", "a"), ("stop", "ctl")]))
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ←
              alongside fixture
                (driveTicks fixture period 2)
                (run fixture runtime (tickConfig fixture period (Just 9) [script (scriptAt paths 0), everyTick (scriptAt paths 1)]) >>= expectRan)
            reportEnding report `shouldBe` EndedAllInstances
            reportTicks report `shouldBe` 2
            statusOf report `shouldBe` StatusSuccess
            recorded fixture >>= (`shouldBe` ["ctl true true", "shutdown a stopped"])

  describe "admission, one script at a time" $ do
    let initing name = ["function init(self) fx.record('" <> name <> " init') end"] <> eventOnly name
        holding name = ["function init(self) fx.record('" <> name <> " init'); fx.block('" <> name <> "') end"] <> eventOnly name
    it "admits each script only after the previous instance's init has finished, so TIDs and inits follow the script order, on a tick VM" $ bounded $ do
      fixture ← newRFixture
      withScripts [("a.lua", lua (holding "a")), ("b.lua", lua (initing "b")), ("c.lua", lua (initing "c"))] $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              ( awaitGate fixture "a"
                  >> replicateM_ 300 yield
                  -- While a's init is held nothing behind it has been admitted, so no other init has run.
                  >> (recorded fixture `shouldReturn` ["a init"])
                  >> openGate fixture "a"
                  >> driveTicks fixture period 1
              )
              (run fixture runtime (tickConfig fixture period (Just 1) (map script paths)) >>= expectRan)
          recorded fixture >>= \seen → take 3 seen `shouldBe` ["a init", "b init", "c init"]
          let numbers = map instanceLocal (tidsOf report)
          numbers `shouldBe` take 3 [head' numbers ..]
    it "admits each script only after the previous instance's init has finished, on an elapsed VM" $ bounded $ do
      fixture ← newRFixture
      withScripts [("a.lua", lua (holding "a")), ("b.lua", lua (initing "b"))] $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              ( awaitGate fixture "a"
                  >> replicateM_ 300 yield
                  >> (recorded fixture `shouldReturn` ["a init"])
                  >> openGate fixture "a"
                  >> awaitOut fixture 3
                  >> setStop fixture True
              )
              (run fixture runtime (config fixture (map script paths)) >>= expectRan)
          recorded fixture >>= \seen → take 2 seen `shouldBe` ["a init", "b init"]
          map instanceLocal (tidsOf report) `shouldBe` take 2 [head' (map instanceLocal (tidsOf report)) ..]
    it "admits no further script when the duration limit is reached while an init is held, and tables the instances admitted" $ bounded $ do
      fixture ← newRFixture
      withScripts [("a.lua", lua (holding "a")), ("b.lua", lua (initing "b"))] $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              (awaitGate fixture "a" >> awaitLive fixture 1 >> tickClock fixture (2 * period) >> fireLive fixture >> openGate fixture "a")
              (run fixture runtime ((tickConfig fixture period Nothing (map script paths)) {runnerLimit = Just (ns period)}) >>= expectRan)
          reportEnding report `shouldBe` EndedLimit
          map instanceNameText (instancesOf report) `shouldBe` ["a.lua"]
          recorded fixture `shouldReturn` ["a init", "shutdown a stopped"]
          liveCount fixture `shouldReturn` 0
    it "admits no further script when the stop request arrives while an init is held, on a tick VM" $ bounded $ do
      fixture ← newRFixture
      withScripts [("a.lua", lua (holding "a")), ("b.lua", lua (initing "b"))] $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              (awaitGate fixture "a" >> setStop fixture True >> openGate fixture "a")
              (run fixture runtime (tickConfig fixture period Nothing (map script paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          map instanceNameText (instancesOf report) `shouldBe` ["a.lua"]
          recorded fixture `shouldReturn` ["a init", "shutdown a stopped"]

  describe "the other ways a run on ticks ends" $ do
    it "ends as a startup failure when a source does not load, granting no tick and arming nothing" $ bounded $ do
      fixture ← newRFixture
      withBoundary $ \_ runtime → do
        report ← run fixture runtime (tickConfig fixture period (Just 3) [script "/does/not/exist.lua"]) >>= expectRan
        reportEnding report `shouldBe` EndedStartupFailure
        statusOf report `shouldBe` StatusFailure
        reportTicks report `shouldBe` 0
        reportEvents report `shouldBe` noTally
        regCount fixture `shouldReturn` 0
    it "never grants a tick whose deadline the clock cannot represent, and the stop request ends the run" $ bounded $ do
      fixture ← newRFixture
      withScripts [("l.lua", lua (counting "l"))] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (awaitOut fixture 3 >> tickClock fixture (10 * period) >> setStop fixture True)
              (run fixture runtime ((tickConfig fixture period Nothing [everyTick (scriptAt paths 0)]) {runnerTick = Just maximumDuration}) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          reportTicks report `shouldBe` 0
          liveCount fixture `shouldReturn` 0

  describe "failures of the host on a tick VM" $
    it "retires the owner and cancels every timer, then propagates the failure that arrived during a tick" $ bounded $ do
      fixture ← newRFixture
      withScripts [("w.lua", lua ["function update(self, dt) fx.fail('host') end"]), ("ev.lua", lua (eventOnly "ev"))] $ \paths → do
        failure ← expectFatal $ \_ runtime →
          alongside fixture
            -- Both timers are armed: the duration limit's and the driver's.
            (awaitLive fixture 2 >> tickClock fixture period >> fireLive fixture)
            (run fixture runtime ((tickConfig fixture period (Just 5) [everyTicks 1 (script (scriptAt paths 0)), script (scriptAt paths 1)]) {runnerLimit = Just (ns (100 * period))}) >>= \_ → pure ())
        (case failure of ExceptionWithContext _ raised → raised) `shouldSatisfy` brokenIs "host"
        -- Lua was not entered again: no shutdown ran, and no registration is left armed.
        recorded fixture `shouldReturn` []
        liveCount fixture `shouldReturn` 0
  where
    head' = \case
      value : _ → value
      [] → 0
