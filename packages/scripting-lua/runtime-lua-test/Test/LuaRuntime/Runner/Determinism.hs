-- | What a run on ticks does the same however it is paced, and the coordination that makes it so: which
-- events are produced, in what order and to whom does not depend on when the runner's own thread resumes.
module Test.LuaRuntime.Runner.Determinism (spec) where

import Control.Concurrent (yield)
import Control.Monad (forM_, replicateM_, when)
import Data.Char (isDigit)
import Data.List (sortOn)
import Data.Ord (Down (Down))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Runner
import System.FilePath (takeDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (Gated (..), bounded, withBoundaryOpening)

period ∷ Word64
period = 1000

-- | Find an instance of the owner by name, as a script does.
tidOf ∷ [Text]
tidOf =
  [ "local function tid_of(name)"
  , "  local me = lifecycle.owners().owners[1]"
  , "  local seen = lifecycle.inspect_owner({runtime = me.runtime, owner = me.owner})"
  , "  for _, snapshot in ipairs(seen.instances) do"
  , "    if snapshot.name == name then return snapshot.tid end"
  , "  end"
  , "end"
  ]

-- | The scripts every run of these examples has, in the order they are admitted.
scenario ∷ [(FilePath, [Text])]
scenario =
  [ ( "watch.lua"
    , [ "local base"
      , "function init(self, api)"
      , "  base = lifecycle.self().id"
      , "  api.subscribe('instances', function(self, e)"
      , "    local p = e.payload"
      , "    fx.record('watch ' .. p.event .. ' ' .. p.name .. ' ' .. (p.outcome or '-') .. ' t' .. (p.tid.id - base) .. ' @' .. e.tick .. ' #' .. e.sequence)"
      , "  end)"
      , "end"
      ]
    )
  , -- Subscribes, then unsubscribes in its own run, which the owner dispatches as soon as its init is done.
    ( "quick.lua"
    , [ "local handle"
      , "function init(self, api)"
      , "  handle = api.subscribe('instances', function(self, e) fx.record('quick saw ' .. e.payload.event .. ' ' .. e.payload.name) end)"
      , "  fx.record('quick init')"
      , "end"
      , "function run(self, api) fx.record('quick run ' .. tostring(api.unsubscribe(handle))) end"
      ]
    )
  , -- A one-shot that is ready again, and again, before the first tick is granted.
    ( "yielder.lua"
    , [ "function run(self)"
      , "  for i = 1, 3 do fx.record('yield ' .. i); fx.yield() end"
      , "  fx.record('yield done')"
      , "end"
      ]
    )
  , ("badinit.lua", ["function init(self) error('no init') end"])
  , ("finisher.lua", ["function run(self) fx.record('finisher run') end"])
  , ( "looper.lua"
    , [ "local n = 0"
      , "function update(self, dt) n = n + 1; fx.record('looper ' .. n) end"
      , "function shutdown(self, reason) fx.record('shutdown looper ' .. reason) end"
      ]
    )
  , -- Pauses itself and waits a tick: the pause is applied at the tick, before the wake it would have had, and a
    -- logical control from another instance resumes it.
    ( "pauser.lua"
    , [ "function run(self)"
      , "  fx.record('pauser start')"
      , "  lifecycle.pause(lifecycle.self())"
      , "  fx.wait_ticks(1)"
      , "  fx.record('pauser resumed')"
      , "end"
      ]
    )
  , ( "resumer.lua"
    , tidOf
        <> [ "local done = false"
           , "function update(self, dt)"
           , "  if done then return end"
           , "  done = true"
           , "  local r = lifecycle.resume(tid_of('pauser.lua'))"
           , "  fx.record('resume ' .. tostring(r.accepted))"
           , "end"
           ]
    )
  , ( "bad2.lua"
    , [ "local n = 0"
      , "function update(self, dt) n = n + 1; if n == 2 then error('bad2') end end"
      ]
    )
  ]

-- | The tick each script's interval is, where it has one.
intervals ∷ [(FilePath, Integer)]
intervals = [("looper.lua", 2), ("resumer.lua", 3), ("bad2.lua", 1)]

scriptsAt ∷ [FilePath] → [Script]
scriptsAt paths = [maybe id everyTicks (lookup name intervals) (script path) | ((name, _), path) ← zip scenario paths]

-- | Run the scenario for six ticks, paced as this says, and answer everything an observer could compare:
-- what the scripts recorded, what the sinks were handed, and what the report says, with the identities
-- that are unique to a run replaced by the instance's order in it.
transcript ∷ (RFixture → RunnerConfig → RunnerConfig) → (RFixture → IO ()) → IO [Text]
transcript adapt pace = do
  fixture ← newRFixture
  withScripts [(name, lua body) | (name, body) ← scenario] $ \paths →
    withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
      report ←
        alongside fixture
          (pace fixture)
          (run fixture runtime (adapt fixture (tickConfig fixture period (Just 6) (scriptsAt paths))) >>= expectRan)
      seen ← recorded fixture
      out ← outLines fixture
      err ← errLines fixture
      let names = [(tidText (instanceTid item), "T" <> Text.pack (show index)) | (index, item) ← zip [0 ∷ Int ..] (instancesOf report)]
          directory = Text.pack (takeDirectory (head' paths))
          canonical line = foldl (\acc (from, to) → Text.replace from to acc) (scrubVm (Text.replace directory "<dir>" line)) (sortOn (Down . Text.length . fst) names)
          tally = reportEvents report
      pure $
        map canonical seen
          <> ["-- out"]
          -- A table's columns are as wide as the identities in it are long, which differs from run to run.
          <> map (Text.unwords . Text.words . canonical) out
          <> ["-- err"]
          <> map canonical err
          <> [ "-- report"
             , Text.pack (show (reportEnding report, reportStatus report, reportTicks report))
             , Text.pack (show tally)
             ]
          <> [ Text.intercalate " " [instanceNameText item, Text.pack (show (instanceStatus item)), Text.pack (show (instanceShutdown item)), endWord (instanceEnd item)]
             | item ← instancesOf report
             ]
  where
    head' = \case
      path : _ → path
      [] → ""
    endWord = \case
      EndCompleted → "completed"
      EndStopped → "stopped"
      EndFailed _ → "failed"
      EndDiscarded _ → "discarded"

-- | Ticks driven one at a time, as the driver arms its timer for each.
promptly ∷ RFixture → IO ()
promptly fixture = driveTicks fixture period 6

-- | Each tick granted only after the runner's and the owner's threads have been given many turns.
slowly ∷ RFixture → IO ()
slowly fixture = forM_ [1 .. 6 ∷ Int] $ \number → do
  awaitLive fixture 1
  replicateM_ 300 yield
  before ← regCount fixture
  tickClock fixture period
  fireLive fixture
  when (number < 6) (awaitCount (regCount fixture) (before + 1))

-- | The identity of a VM is unique to a process, not to a run.
scrubVm ∷ Text → Text
scrubVm line = case Text.breakOn "VmIdentity " line of
  (before, "") → before
  (before, after) → before <> "VmIdentity _" <> scrubVm (Text.dropWhile isDigit (Text.drop (Text.length "VmIdentity ") after))

spec ∷ Spec
spec = describe "determinism" $ do
  let baseline = transcript (\_ c → c) promptly
      variants ∷ [(String, RFixture → RunnerConfig → RunnerConfig, RFixture → IO ())]
      variants =
        [ ( "the runner held in the write of the start table while the clock moves four ticks"
          , \fixture → gatedOn fixture startTitle "table"
          , \fixture → awaitGate fixture "table" >> tickClock fixture (4 * period) >> openGate fixture "table" >> promptly fixture
          )
        , ( "the runner held in the report of an init that failed, while scripts are being admitted"
          , \fixture → gatedErrorsOn fixture "badinit.lua" "rep"
          , \fixture → awaitGate fixture "rep" >> tickClock fixture (3 * period) >> openGate fixture "rep" >> promptly fixture
          )
        , ( "the runner held in the report of a failure at the second tick, and the clock far past the rest"
          , \fixture → gatedErrorsOn fixture "bad2.lua" "rep"
          , \fixture → driveTicks fixture period 2 >> awaitGate fixture "rep" >> tickClock fixture (10 * period) >> openGate fixture "rep"
          )
        , ( "the clock far past every deadline before the first tick is granted"
          , \_ → id
          , \fixture → awaitLive fixture 1 >> tickClock fixture (20 * period) >> fireLive fixture
          )
        , ( "every tick granted only after the runner and the owner have been given many turns"
          , \_ → id
          , slowly
          )
        ]
  it "runs the scenario as the contract says, a ready, yielding one-shot first and a paused one resumed by a control" $ bounded $ do
    first ← baseline
    -- A ready, yielding one-shot ran to its end before the first tick; a one-shot that unsubscribed at once heard
    -- nothing; a paused one-shot was resumed by a control from another instance, at the tick it assigned.
    take 8 first `shouldBe` ["quick init", "quick run true", "yield 1", "yield 2", "yield 3", "yield done", "finisher run", "pauser start"]
    forM_ ["watch started quick.lua - t1 @1 #1", "watch ended quick.lua completed t1 @1 #8", "resume true", "pauser resumed"] $ \line →
      first `shouldSatisfy` elem line
    filter (Text.isPrefixOf "quick saw") first `shouldBe` []
    again ← baseline
    again `shouldBe` first
  forM_ variants $ \(label, adapt, pace) →
    it ("gives the same script output, events with their ticks and places, tables and report with " <> label) $ bounded $ do
      first ← baseline
      other ← transcript adapt pace
      -- The first line that differs, so a failure says what moved.
      take 1 [(left, right) | (left, right) ← zip first other, left /= right] `shouldBe` []
      length other `shouldBe` length first
