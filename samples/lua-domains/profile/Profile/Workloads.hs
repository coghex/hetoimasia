-- | The bounded profiling workloads of the two-domain sample (#500 requirement 8; D-45, P-11).
--
-- Each workload runs a bounded session and prints /one record/ for it, in a fixed shape: @probe: NAME | key=value | ...@.
-- Nothing here is a threshold or an assertion on a number: the UI's update cadence, gameplay's throughput, the
-- scheduler's counters and the RTS statistics are measurements, printed for whoever reads them, and a wall-clock figure is
-- never an input to a check. The examples fail only when a session cannot be run (an infrastructure failure), never for
-- what it measured. The one comparison the probe makes is the digest trace's, over a repeat of requirement 5's runs much
-- larger than the routine suite's; a divergence there is printed as a finding, and is the sample's to be told of.
--
-- The runtime options in force are printed first: this probe is built @-threaded -with-rtsopts=-N2 -T@, the threaded runtime
-- with two capabilities and its statistics readable, as the executable and the suite are built, plus @-T@.
module Profile.Workloads (spec) where

import Control.Concurrent (getNumCapabilities, rtsSupportsBoundThreads)
import Control.Monad (forM, forM_, replicateM, when)
import Data.ByteString (ByteString)
import Data.List (sort)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumProcessors)
import GHC.Stats (GCDetails (gcdetails_live_bytes), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Foundation.Time (durationNanoseconds)
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsGameplay, domainsUi)
  , DomainsConfig (configGameplaySource, configInput, configTicks, configUiInterval, configUiSource)
  , SessionReport (reportCounts, reportTicks, reportUiUpdates)
  , Started (startedOwner)
  , defaultConfig
  , runSession
  )
import Hetoimasia.Sample.LuaDomains.Canonical (digestHex, firstDivergence)
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Normal), scriptedInputs)
import Hetoimasia.Sample.LuaDomains.Tally (Counts (countAccepted, countApplied, countStale))
import Hetoimasia.Scripting.Lua.Owner (Library (LibraryBase), chunkName, evalOwned, vmConfig, withVmOwner)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledDiagnostics, scheduledEndpoint)
import Hetoimasia.Scripting.Lua.Scheduler (Diagnostics (..))
import Control.Concurrent.STM (atomically)
import System.Mem (performMajorGC)
import Test.Domains.FixedLog
import Test.Domains.Support
import Test.Hspec

-- Records ---------------------------------------------------------------------------------

-- | One workload's record: its name and what was measured, as one line.
record ∷ String → [(String, String)] → IO ()
record name fields = putStrLn (unwords' ("probe: " <> name : [key <> "=" <> value | (key, value) ← fields]))
  where
    unwords' = foldr1 (\a b → a <> " | " <> b)

-- | The distribution of some intervals, in microseconds: how many there are and their minimum, median, 90th percentile and
-- maximum.
summary ∷ [Word64] → [(String, String)]
summary [] = [("count", "0")]
summary intervals =
  [ ("count", show (length intervals))
  , ("min_us", micros (head' sorted))
  , ("median_us", micros (sorted !! (length sorted `div` 2)))
  , ("p90_us", micros (sorted !! min (length sorted - 1) ((length sorted * 9) `div` 10)))
  , ("max_us", micros (last sorted))
  ]
  where
    sorted = sort intervals
    head' = foldr1 const
    micros nanoseconds = show (nanoseconds `div` 1000)

-- | The intervals between consecutive readings.
gaps ∷ [Word64] → [Word64]
gaps readings = zipWith (-) (drop 1 readings) readings

-- | The RTS statistics a workload changed, and where it ended: collections, major collections, bytes allocated, the time the
-- collector took, the most live bytes seen and the live bytes after a collection at the end. Empty if the statistics are not
-- readable (this probe is built with them).
rtsAround ∷ IO a → IO (a, [(String, String)])
rtsAround action = do
  enabled ← getRTSStatsEnabled
  if not enabled
    then (\result → (result, [("rts_stats", "disabled")])) <$> action
    else do
      first ← getRTSStats
      result ← action
      performMajorGC
      last' ← getRTSStats
      pure
        ( result
        , [ ("gcs", show (gcs last' - gcs first))
          , ("major_gcs", show (major_gcs last' - major_gcs first))
          , ("allocated_bytes", show (allocated_bytes last' - allocated_bytes first))
          , ("gc_pause_total_us", show ((fromIntegral (gc_elapsed_ns last' - gc_elapsed_ns first) ∷ Word64) `div` 1000))
          , ("max_live_bytes", show (max_live_bytes last'))
          , ("live_bytes_at_end", show (gcdetails_live_bytes (gc last')))
          ]
        )

-- The UI's cadence -----------------------------------------------------------------------

-- | The updates the UI is made to do in each cadence workload.
cadenceUpdates ∷ Int
cadenceUpdates = 100

-- | The UI behavior of the cadence workloads: the production one's shape, with the clock's reading kept when each update
-- completes.
stampingUi ∷ ByteString
stampingUi =
  luaLines
    [ "function update(self, dt)"
    , "  fx.stamp()"
    , "  ui.updated()"
    , "end"
    ]

-- | The intervals between the UI's completed updates in the slice of them from the nth to the mth, in nanoseconds.
sliceGaps ∷ Fx → Int → Int → IO [Word64]
sliceGaps fx from to = do
  stamps ← fxStamps fx
  pure (gaps (take (to - from + 1) (drop from stamps)))

-- | How fast this machine runs the CPU-bound loop: iterations a second, the best of three short runs.
iterationsPerSecond ∷ IO Double
iterationsPerSecond = do
  rates ← replicateM 3 $
    withVmOwner (vmConfig [LibraryBase]) $ \vm → do
      started ← getMonotonicTimeNSec
      evalOwned vm (chunkName "calibration") (luaLines ["local x = 0 for i = 1, 2000000 do x = x + i % 7 end"])
      finished ← getMonotonicTimeNSec
      pure (2000000 / (fromIntegral (finished - started) / 1.0e9))
  pure (maximum rates)

-- | The UI's cadence with gameplay idle: no tick is granted while the UI does its updates.
cadenceIdle ∷ IO ()
cadenceIdle =
  withRealSample (\config → config {configUiSource = stampingUi}) $ \fx domains → do
    awaitUpdates domains cadenceUpdates
    intervals ← sliceGaps fx 0 (cadenceUpdates - 1)
    record "ui-cadence" (("gameplay", "idle") : summary intervals)

-- | The UI's cadence while gameplay is held inside a running segment, a gate a binding holds it on.
cadenceHeld ∷ IO ()
cadenceHeld =
  withRealSample (\config → config {configUiSource = stampingUi, configGameplaySource = luaLines ["function update(self, dt) fx.hold('probe') staging.finish() end"]}) $ \fx domains →
    withReleased fx ["probe"] $ do
      _ ←
        alongside
          ( do
              awaitEntered fx "probe"
              begun ← updatesNow domains
              awaitUpdates domains (begun + cadenceUpdates)
              intervals ← sliceGaps fx begun (begun + cadenceUpdates - 1)
              record "ui-cadence" (("gameplay", "held") : summary intervals)
              releaseGate fx "probe"
          )
          (stepCommitted domains)
      pure ()

-- | The UI's cadence while gameplay runs a pure-Lua computation with no binding call and no yield, sized by this machine's
-- speed to last about a quarter of a second.
cadenceCpuBound ∷ IO ()
cadenceCpuBound = do
  rate ← iterationsPerSecond
  let iterations = max 1000000 (min 4000000000 (ceiling (rate * 0.25))) ∷ Word64
  withRealSample
    ( \config →
        config
          { configUiSource = stampingUi
          , configGameplaySource =
              luaLines
                [ "function update(self, dt)"
                , "  fx.mark('begin')"
                , "  local x = 0"
                , "  for i = 1, " <> Text.pack (show iterations) <> " do x = x + i % 7 end"
                , "  fx.mark('end')"
                , "  staging.finish()"
                , "end"
                ]
          }
    )
    $ \fx domains → do
      _ ← generous (stepCommitted domains)
      marks ← fxMarks fx
      case marks of
        [("begin", begun), ("end", ended)] → do
          intervals ← sliceGaps fx begun (ended - 1)
          record "ui-cadence" ([("gameplay", "cpu-bound"), ("iterations", show iterations), ("updates_during", show (ended - begun))] <> summary intervals)
        other → fail ("unexpected marks: " <> show other)

-- Throughput and counters -----------------------------------------------------------------

-- | The UI behavior of the busy workloads: reads the view over and over, draws from its own random stream and offers
-- intentions of its own (which a live session accepts: they are what the gameplay session is given).
busyUi ∷ ByteString
busyUi =
  luaLines
    [ "local last_status"
    , "function update(self, dt)"
    , "  local status = view.status()"
    , "  if status ~= last_status then ui.saw(status) last_status = status end"
    , "  for i = 1, 10 do"
    , "    local present, _, _, version = view.entity(i % 8)"
    , "    intent.submit(view.session(), view.tick(), i % 8, version, 1, 1)"
    , "    local draw = math.random(1, 1000) + math.random()"
    , "  end"
    , "  ui.updated()"
    , "end"
    ]

-- | The ticks of the throughput workloads.
throughputTicks ∷ Word64
throughputTicks = 300

-- | Gameplay's throughput over a bounded session: the ticks committed and the time they took, with the UI idle (its clock
-- never moves) or busy (on the real clock and timer, offering intentions of its own), and what the RTS did meanwhile.
throughput ∷ Bool → IO ()
throughput busy = do
  ((committed, elapsed, updates), rts) ← rtsAround $
    if busy
      then withRealSample (\config → config {configTicks = Just throughputTicks, configUiSource = busyUi, configInput = scriptedInputs}) $ \_ domains → measure domains
      else withSample (\config → config {configTicks = Just throughputTicks}) $ \_ _ domains → measure domains
  let seconds = fromIntegral elapsed / 1.0e9 ∷ Double
  record
    "gameplay-throughput"
    ( [ ("ui", if busy then "busy" else "idle")
      , ("ticks", show committed)
      , ("elapsed_ms", show (elapsed `div` 1000000))
      , ("ticks_per_second", show (round (fromIntegral committed / max 1.0e-9 seconds) ∷ Int))
      , ("ui_updates", show updates)
      ]
        <> rts
    )
  where
    measure domains = do
      started ← getMonotonicTimeNSec
      report ← generous (runSession domains)
      finished ← getMonotonicTimeNSec
      pure (reportTicks report, finished - started, reportUiUpdates report)

-- | The scheduler's counters for both owners after a bounded session with a busy UI: segments by class, overruns and where
-- they were, the queue's and the active set's high-water marks, grants, and what ended how.
counters ∷ IO ()
counters =
  withRealSample (\config → config {configTicks = Just throughputTicks, configUiSource = busyUi, configInput = scriptedInputs}) $ \_ domains → do
    report ← generous (runSession domains)
    forM_ [("gameplay", startedOwner (domainsGameplay domains)), ("ui", startedOwner (domainsUi domains))] $ \(name, owner) → do
      d ← atomically (scheduledDiagnostics (scheduledEndpoint owner))
      record
        "scheduler-counters"
        [ ("owner", name)
        , ("admitted", show (diagAdmitted d))
        , ("completed", show (diagCompleted d))
        , ("failed", show (diagFailed d))
        , ("cancelled", show (diagCancelled d))
        , ("segments_by_class", show (diagSegmentsByClass d))
        , ("yielded", show (diagYielded d))
        , ("waiting", show (diagWaiting d))
        , ("overruns", show (diagOverruns d))
        , ("overrun_sites", take 400 (show (diagOverrunSites d)))
        , ("queue_high_water", show (diagQueueHighWater d))
        , ("active_high_water", show (diagActiveHighWater d))
        , ("grants_accepted", show (diagGrantsAccepted d))
        , ("grants_refused", show (diagGrantsRefused d))
        , ("tick", show (diagTick d))
        ]
    record
      "intentions"
      [("accepted", show (countAccepted (reportCounts report))), ("applied", show (countApplied (reportCounts report))), ("stale", show (countStale (reportCounts report)))]

-- The repeat ---------------------------------------------------------------------------------

-- | How many times each disturbance of requirement 5 is repeated: far more than the routine suite does.
largeRepeat ∷ Int
largeRepeat = 50

-- | Requirement 5's runs, repeated 'largeRepeat' times each: how many of the runs gave the baseline's trace tick by tick, and
-- where the first that did not diverged.
qualifyAgain ∷ IO ()
qualifyAgain = do
  let ticks = 16 ∷ Word64
  log' ← generateLog 1 ticks False
  baseline ← traceOf <$> runFixed undisturbed log' ticks 1 Normal
  record "qualify-repeat" [("disturbance", "baseline"), ("trace_entries", show (length baseline)), ("final_trace_digest", Text.unpack (digestHex (last baseline)))]
  forM_ [gated, spun 0, spun 17, uiHeavy, gapped, undisturbed] $ \disturbance → do
    traces ← forM [1 .. largeRepeat] (const (traceOf <$> runFixed disturbance log' ticks 1 Normal))
    let divergences = [(run, at) | (run, trace) ← zip [1 ∷ Int ..] traces, Just at ← [firstDivergence trace baseline]]
    record
      "qualify-repeat"
      [ ("disturbance", disturbanceName disturbance)
      , ("runs", show largeRepeat)
      , ("identical_to_baseline", show (length traces - length divergences))
      , ("diverged", show (length divergences))
      , ("first_divergence", show (take 1 divergences))
      ]

spec ∷ Spec
spec = describe "the profiling probe" $ do
  it "prints the runtime options in force" $ do
    capabilities ← getNumCapabilities
    processors ← getNumProcessors
    enabled ← getRTSStatsEnabled
    record
      "rts-options"
      [ ("built_with", "-threaded -rtsopts -with-rtsopts=-N2 -T")
      , ("threaded", show rtsSupportsBoundThreads)
      , ("capabilities", show capabilities)
      , ("processors", show processors)
      , ("rts_statistics", if enabled then "enabled" else "disabled")
      , ("ui_interval_ns", show (durationNanoseconds (configUiInterval defaultConfig)))
      ]
    rtsSupportsBoundThreads `shouldBe` True
    when (capabilities < 2) (expectationFailure "the probe needs at least two capabilities")

  it "measures the UI's update cadence while gameplay is idle" cadenceIdle
  it "measures the UI's update cadence while gameplay is held in a running segment" cadenceHeld
  it "measures the UI's update cadence while gameplay is CPU-bound" cadenceCpuBound
  it "measures gameplay's throughput with the UI idle" (throughput False)
  it "measures gameplay's throughput with the UI busy" (throughput True)
  it "reads the scheduler's counters after a session with a busy UI" counters
  it "repeats requirement 5's runs many times and prints how many matched the baseline's trace" qualifyAgain

