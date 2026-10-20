-- | The instance events: what an event is, which are produced, in what order and to whom, how the
-- engine's answer to each delivery is classified and counted, and what a refusal does to a run.
module Test.LuaRuntime.Runner.Events (spec) where

import Control.Monad (forM_)
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance (InstanceSnapshot (snapshotPhase), isTerminal)
import Hetoimasia.Scripting.Lua.Provider (EventAnswer (..))
import Hetoimasia.Scripting.Lua.Runner
import Hetoimasia.Scripting.Lua.Runner.Internal (AnswerClass (..), Refusal (..), classifyAnswer)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (Gated (..), bounded, withBoundary, withBoundaryOpening)

-- | A watcher's init: subscribe to the instances and record every event, with its tick.
watching ∷ [Text]
watching =
  [ "function init(self, api)"
  , "  api.subscribe('instances', function(self, e)"
  , "    local p = e.payload"
  , "    fx.record(p.event .. ' ' .. (p.name or '?') .. ' ' .. (p.outcome or '-') .. ' @' .. e.tick)"
  , "  end)"
  , "end"
  ]

-- | The pairs of an owner's instances as a script sees them, by name.
findByName ∷ [Text]
findByName =
  [ "local function find(name)"
  , "  local me = lifecycle.owners().owners[1]"
  , "  local seen = lifecycle.inspect_owner({runtime = me.runtime, owner = me.owner})"
  , "  for _, snapshot in ipairs(seen.instances) do"
  , "    if snapshot.name == name then return snapshot.tid end"
  , "  end"
  , "end"
  ]

eventOnly ∷ [Text]
eventOnly = ["function shutdown(self, reason) fx.record('shutdown event ' .. reason) end"]

tickLength ∷ Word64
tickLength = 1000

spec ∷ Spec
spec = describe "events" $ do
  describe "what an engine's answer to a delivery means" $ do
    let classes =
          [ (EventAdmitted, AnswerAdmitted)
          , (EventStaged, AnswerStaged)
          , (EventQueueFull, AnswerRefused RefusedQueueFull)
          , (EventStagingFull, AnswerRefused RefusedStagingFull)
          , (EventEnded, AnswerEnded)
          , (EventCoalesced, AnswerDefect EventCoalesced)
          , (EventRefusedValue, AnswerDefect EventRefusedValue)
          , (EventLate, AnswerDefect EventLate)
          , (EventDuplicate, AnswerDefect EventDuplicate)
          , (EventUnassigned, AnswerDefect EventUnassigned)
          , (EventNotLogical, AnswerDefect EventNotLogical)
          ]
    forM_ classes $ \(answer, expected) →
      it ("classifies " <> show answer <> " as " <> show expected) $
        classifyAnswer answer `shouldBe` expected
    it "answers for every constructor of EventAnswer" $
      length classes `shouldBe` 11

  describe "the events a watcher sees" $ do
    it "tells a watcher of every start and end, in TID order with the starts first, at the first tick the owner has not begun" $ bounded $ do
      fixture ← newRFixture
      withScripts
        [ ("watch.lua", lua watching)
        , ("ok.lua", lua ["function run(self) fx.record('run ok') end"])
        , ("bad.lua", lua ["function run(self) error('boom') end"])
        , ("stopper.lua", lua ["function init(self) lifecycle.stop(lifecycle.self()) end"])
        , ("failinit.lua", lua ["function init(self) error('no init') end"])
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ←
              alongside fixture
                (driveTicks fixture tickLength 2)
                (run fixture runtime (tickConfig fixture tickLength (Just 2) (map noWait paths)) >>= expectRan)
            reportEnding report `shouldBe` EndedTickLimit
            statusOf report `shouldBe` StatusFailure
            -- The ready one-shots ran before the first tick; everything produced before it is delivered at it.
            recorded fixture
              >>= ( `shouldBe`
                      [ "run ok"
                      , "started watch.lua - @1"
                      , "started ok.lua - @1"
                      , "started bad.lua - @1"
                      , "started stopper.lua - @1"
                      , "ended ok.lua completed @1"
                      , "ended bad.lua failed @1"
                      , "ended failinit.lua failed @1"
                      , "ended stopper.lua stopped @2"
                      ]
                  )
            reportTicks report `shouldBe` 2

    it "gives a watcher a TID it can use with the lifecycle namespace" $ bounded $ do
      fixture ← newRFixture
      let watcher =
            findByName
              <> [ "function init(self, api)"
                 , "  api.subscribe('instances', function(self, e)"
                 , "    local p = e.payload"
                 , "    if p.event == 'started' and p.name == 'target.lua' then"
                 , "      local seen = lifecycle.inspect(p.tid)"
                 , "      fx.record('inspect ' .. tostring(seen.ok) .. ' ' .. seen.snapshot.name .. ' ' .. seen.snapshot.status)"
                 , "      local paused = lifecycle.pause(p.tid)"
                 , "      fx.record('pause ' .. tostring(paused.accepted))"
                 , "    end"
                 , "    if p.event == 'ended' then fx.record('ended ' .. p.name .. ' ' .. p.outcome) end"
                 , "  end)"
                 , "end"
                 ]
      withScripts [("watch.lua", lua watcher), ("target.lua", lua eventOnly)] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 3)
              (run fixture runtime (tickConfig fixture tickLength (Just 3) (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          recorded fixture
            >>= ( `shouldBe`
                    [ "inspect true target.lua active"
                    , "pause true"
                    , "shutdown event stopped"
                    ]
                )

    it "makes an event's fields what the contract says: a name always, an outcome only on an end" $ bounded $ do
      fixture ← newRFixture
      let watcher =
            [ "function init(self, api)"
            , "  api.subscribe('instances', function(self, e)"
            , "    local p = e.payload"
            , "    local keys = {}"
            , "    for k in pairs(p) do keys[#keys + 1] = k end"
            , "    table.sort(keys)"
            , "    fx.record(p.event .. ': ' .. table.concat(keys, ','))"
            , "  end)"
            , "end"
            ]
      withScripts [("watch.lua", lua watcher), ("one.lua", lua ["function run(self) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 1)
              (run fixture runtime (tickConfig fixture tickLength (Just 1) (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          recorded fixture
            >>= ( `shouldBe`
                    [ "started: event,name,tid"
                    , "started: event,name,tid"
                    , "ended: event,name,outcome,tid"
                    ]
                )

    it "produces an end for an instance whose init failed, and no start" $ bounded $ do
      fixture ← newRFixture
      withScripts [("watch.lua", lua watching), ("bad.lua", lua ["function init(self) error('no') end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 1)
              (run fixture runtime (tickConfig fixture tickLength (Just 1) (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          recorded fixture >>= (`shouldBe` ["started watch.lua - @1", "ended bad.lua failed @1"])

    it "reaches only the subscriptions that exist when an event is produced, and replays nothing" $ bounded $ do
      fixture ← newRFixture
      let late =
            [ "function run(self, api)"
            , "  api.subscribe('instances', function(self, e)"
            , "    fx.record('late saw ' .. e.payload.event .. ' ' .. e.payload.name)"
            , "  end)"
            , "end"
            ]
      withScripts
        [ ("watch.lua", lua watching)
        , ("one.lua", lua ["function run(self) end"])
        , ("late.lua", lua late)
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ←
              alongside fixture
                (driveTicks fixture tickLength 1)
                (run fixture runtime (tickConfig fixture tickLength (Just 1) (map noWait paths)) >>= expectRan)
            reportEnding report `shouldBe` EndedTickLimit
            recorded fixture
              >>= ( `shouldBe`
                      [ "started watch.lua - @1"
                      , "started one.lua - @1"
                      , "started late.lua - @1"
                      , "ended one.lua completed @1"
                      , "ended late.lua completed @1"
                      ]
                  )

    it "delivers one event once to each subscription, in the order of the subscription numbers, each with a place of its own" $ bounded $ do
      fixture ← newRFixture
      let twice =
            [ "function init(self, api)"
            , "  for _, label in ipairs({'A', 'B', 'C'}) do"
            , "    api.subscribe('instances', function(self, e)"
            , "      fx.record(label .. ' ' .. e.payload.event .. ' ' .. e.payload.name .. ' sub=' .. e.subscription .. ' seq=' .. e.sequence .. ' tick=' .. e.tick)"
            , "    end)"
            , "  end"
            , "end"
            ]
      withScripts [("twice.lua", lua twice), ("one.lua", lua ["function run(self) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 1)
              (run fixture runtime (tickConfig fixture tickLength (Just 1) (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          seen ← recorded fixture
          map (Text.take 1) seen `shouldBe` map Text.singleton ("ABCABCABC" ∷ String)
          let sequences = map (field "seq=") seen
              subscriptions = map (field "sub=") seen
          sequences `shouldSatisfy` strictlyIncreasing
          take 3 subscriptions `shouldSatisfy` strictlyIncreasing
          subscriptions `shouldBe` concat (replicate 3 (take 3 subscriptions))
          map (field "tick=") seen `shouldBe` replicate 9 1
          -- Three events (twice and one start, then one end), three deliveries each.
          eventsProduced report `shouldBe` 3
          attemptsMade report `shouldBe` 9

  describe "the ends a run has earned when it ends" $ do
    it "produces and counts every end when every one-shot has completed during admission" $ bounded $ do
      fixture ← newRFixture
      withScripts [("one.lua", lua ["function run(self) end"]), ("two.lua", lua ["function run(self) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (tickConfig fixture tickLength Nothing (map noWait paths)) >>= expectRan
          reportEnding report `shouldBe` EndedAllInstances
          let tally = reportEvents report
          (tallyStarted tally, tallyEnded tally) `shouldBe` (2, 2)
    it "produces and counts the end of the final instance when it ends during a tick" $ bounded $ do
      fixture ← newRFixture
      let selfStopping =
            [ "function init(self, api) api.subscribe('instances', function(self, e) fx.record(e.payload.event .. ' ' .. e.payload.name) end) end"
            , "function update(self, dt) lifecycle.stop(lifecycle.self()) end"
            ]
      withScripts [("a.lua", lua selfStopping)] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 2)
              (run fixture runtime (tickConfig fixture tickLength (Just 9) [everyTicks 1 (script (scriptAt paths 0))]) >>= expectRan)
          reportEnding report `shouldBe` EndedAllInstances
          reportTicks report `shouldBe` 2
          let tally = reportEvents report
          (tallyStarted tally, tallyEnded tally) `shouldBe` (1, 1)
    it "produces and counts the ends of instances that end during the tick that reaches the tick limit" $ bounded $ do
      fixture ← newRFixture
      let selfStopping =
            [ "function update(self, dt) lifecycle.stop(lifecycle.self()) end"
            ]
      withScripts [("watch.lua", lua watching), ("a.lua", lua selfStopping)] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 2)
              (run fixture runtime (tickConfig fixture tickLength (Just 2) [script (scriptAt paths 0), everyTicks 1 (script (scriptAt paths 1))]) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          let tally = reportEvents report
          -- The end of a.lua happened in the second tick and is counted, though no tick follows to deliver it.
          (tallyStarted tally, tallyEnded tally) `shouldBe` (2, 1)
          tallyStaged tally `shouldBe` 3

  describe "events behind a suspended callback" $
    it "does not hold the next tick for events queued behind a callback that waits for a tick" $ bounded $ do
      fixture ← newRFixture
      let slow =
            [ "function init(self, api)"
            , "  api.subscribe('instances', function(self, e)"
            , "    fx.record(e.payload.event .. ' ' .. e.payload.name .. ' @' .. e.tick)"
            , "    fx.wait_ticks(1)"
            , "  end)"
            , "end"
            ]
      withScripts [("slow.lua", lua slow), ("one.lua", lua ["function run(self) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 5)
              (run fixture runtime (tickConfig fixture tickLength (Just 5) (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedTickLimit
          reportTicks report `shouldBe` 5
          -- Three events were assigned the first tick; each callback waits a tick, so they are served one tick
          -- after another, in order, and the driver grants every tick between.
          recorded fixture
            >>= ( `shouldBe`
                    [ "started slow.lua @1"
                    , "started one.lua @1"
                    , "ended one.lua @1"
                    ]
                )

  describe "on an elapsed VM" $
    it "delivers each event on arrival, with no tick, and every delivery is an immediate answer" $ bounded $ do
      fixture ← newRFixture
      withScripts [("watch.lua", lua watching), ("one.lua", lua ["function run(self) end"])] $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (awaitRecorded fixture 3 >> setStop fixture True)
              (run fixture runtime (config fixture (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          recorded fixture
            >>= ( `shouldBe`
                    [ "started watch.lua - @0"
                    , "started one.lua - @0"
                    , "ended one.lua completed @0"
                    ]
                )
          let tally = reportEvents report
          (tallyStarted tally, tallyEnded tally, tallyAttempts tally, tallyAdmitted tally, tallyStaged tally) `shouldBe` (2, 1, 3, 3, 0)

  describe "overload" $ do
    let manyWatches ∷ Int → Maybe Text → [Text]
        manyWatches count after =
          [ "function init(self, api)"
          , "  for i = 1, " <> Text.pack (show count) <> " do"
          , "    api.subscribe('instances', function(self, e) fx.record('seen') end)"
          , "  end"
          ]
            <> maybe [] (\line → ["  " <> line]) after
            <> ["end"]
        oneShots n = [("one" <> show i <> ".lua", lua ["function run(self) end"]) | i ← [1 .. n ∷ Int]]
        accounted tally =
          tallyAttempts tally
            == tallyAdmitted tally + tallyStaged tally + tallyQueueFull tally + tallyStagingFull tally + tallySubscriptionEnded tally
    it "counts a delivery refused because the subscriber's queue is full, on an elapsed VM, and fails nothing" $ bounded $ do
      fixture ← newRFixture
      withScripts (("watch.lua", lua (manyWatches 20 (Just "lifecycle.pause(lifecycle.self())"))) : oneShots 6) $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (awaitSnapshots fixture (\snapshots → length (filter (isTerminal . snapshotPhase) snapshots) >= 6) >> setStop fixture True)
              (run fixture runtime (config fixture (map noWait paths)) >>= expectRan)
          let tally = reportEvents report
          tallyQueueFull tally `shouldSatisfy` (> 0)
          tallyStagingFull tally `shouldBe` 0
          tally `shouldSatisfy` accounted
          tallyWatchersFailed tally `shouldBe` 0
          statusOf report `shouldBe` StatusInterrupted
          pure ()

    it "counts a delivery refused because the owner holds as many events for later ticks as it will, and fails nothing" $ bounded $ do
      fixture ← newRFixture
      withScripts (("watch.lua", lua (manyWatches 17 Nothing)) : oneShots 63) $ \paths →
        withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
          report ←
            alongside fixture
              (awaitGate fixture "table" >> setStop fixture True >> openGate fixture "table")
              (run fixture runtime (gatedOn fixture startTitle "table" (tickConfig fixture tickLength Nothing (map noWait paths))) >>= expectRan)
          let tally = reportEvents report
          tallyStagingFull tally `shouldSatisfy` (> 0)
          tallyStaged tally `shouldBe` fromIntegral runnerStagingBound
          tallyQueueFull tally `shouldBe` 0
          tally `shouldSatisfy` accounted
          tallyWatchersFailed tally `shouldBe` 0
          statusOf report `shouldBe` StatusInterrupted

    it "fails the watcher, once, when events staged for a tick find its queue full at that tick, and goes on" $ bounded $ do
      fixture ← newRFixture
      withScripts (("watch.lua", lua (manyWatches 20 Nothing)) : oneShots 4) $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside fixture
              (driveTicks fixture tickLength 1)
              (run fixture runtime (tickConfig fixture tickLength (Just 5) (map noWait paths)) >>= expectRan)
          -- The watcher failed at the first tick and the one-shots had completed, so that is every instance.
          reportEnding report `shouldBe` EndedAllInstances
          reportTicks report `shouldBe` 1
          statusOf report `shouldBe` StatusFailure
          let tally = reportEvents report
          tallyWatchersFailed tally `shouldBe` 1
          tallyStaged tally `shouldBe` 180
          tallyQueueFull tally `shouldBe` 0
          tallyStagingFull tally `shouldBe` 0
          tally `shouldSatisfy` accounted
          -- Only the watcher failed, and the one-shots completed.
          map (maybe False (const True) . failureOf) (instancesOf report) `shouldBe` [True, False, False, False, False]
          -- Reported once, with the endpoint and the engine's delivery error.
          err ← errLines fixture
          length (filter (Text.isPrefixOf "failure:") err) `shouldBe` 1
          err `shouldSatisfy` any (Text.isInfixOf "delivery to a subscription of instances failed")

  describe "what a script can reach" $
    it "has no binding that starts a request, so the runner's one request endpoint is never used" $ bounded $ do
      fixture ← newRFixture
      let probe =
            [ "function run(self, api)"
            , "  local keys = {}"
            , "  for k in pairs(api) do keys[#keys + 1] = k end"
            , "  table.sort(keys)"
            , "  fx.record('api ' .. table.concat(keys, ','))"
            , "  local globals = {}"
            , "  for k in pairs(_G) do if string.find(string.lower(k), 'request') or string.find(string.lower(k), 'provider') then globals[#globals + 1] = k end end"
            , "  fx.record('globals ' .. #globals)"
            , "end"
            ]
      withScripts [("probe.lua", lua probe)] $ \paths →
        withBoundary $ \_ runtime → do
          report ← run fixture runtime (tickConfig fixture tickLength (Just 1) (map noWait paths)) >>= expectRan
          statusOf report `shouldBe` StatusSuccess
          recorded fixture >>= (`shouldBe` ["api connect,subscribe,unsubscribe", "globals 0"])

-- | The number after this label in a recorded line.
field ∷ Text → Text → Integer
field name line = read (Text.unpack (Text.takeWhile isDigit (Text.drop (Text.length name) (snd (Text.breakOn name line)))))

strictlyIncreasing ∷ [Integer] → Bool
strictlyIncreasing xs = and (zipWith (<) xs (drop 1 xs))

eventsProduced ∷ RunReport → Int
eventsProduced report = fromIntegral (tallyStarted (reportEvents report) + tallyEnded (reportEvents report))

attemptsMade ∷ RunReport → Int
attemptsMade = fromIntegral . tallyAttempts . reportEvents
