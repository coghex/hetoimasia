-- | D-23 qualified on the two-domain sample (#500 requirement 5): the same initial state, content, seed, scheduling
-- configuration and tick-assigned input log give the same digest at every tick boundary, whatever the execution's delays
-- and the UI's activity.
--
-- Every run here has real interpreters under real supervision, the owners' scheduling configuration, the world, the seed and
-- the log held fixed; only when and how much happens around the work changes. The log is the only source of what gameplay is
-- given: each run also shows that what the UI offered was declined before it took a place, that what it asked of gameplay
-- was refused, and that what the session accepted and recorded is exactly the log. Delays and UI activity are produced by
-- gates, the busy work of a binding, the fake clock's updates each awaited by its own completion signal, and a real clock the
-- run does not wait on; nothing waits for time to pass.
--
-- The repeat count is 'repeats' for each disturbance: enough that a disturbance that changed a result would show, and few
-- enough for a routine suite. The optional probe repeats these runs far more.
--
-- Three negative controls show the comparison can fail: a different seed, one record moved to another tick, and two
-- intentions on one entity in one tick exchanged in place order each diverge at the first tick they should.
module Test.Domains.Qualify (spec) where

import Control.Monad (forM_, replicateM_)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configGameplaySource)
  , ReplayOutcome (..)
  , SessionReport (..)
  , SessionStatus (..)
  , renderReport
  )
import Hetoimasia.Sample.LuaDomains.Canonical (Digest, firstDivergence)
import Hetoimasia.Sample.LuaDomains.InputLog (InputLog, Record (..), logOf, logRecords)
import Hetoimasia.Sample.LuaDomains.Intention (Placement (..))
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Failure, Normal, Pause))
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure (..))
import Hetoimasia.Sample.LuaDomains.Tally (ControlCounts (..), Counts (..))
import Test.Domains.FixedLog
import Test.Hspec

-- | The ticks of every run, and the seed.
ticks ∷ Word64
ticks = 16

seed ∷ Word64
seed = 1

-- | What every run over a log that did not fail has: every record released and accepted, none other recorded, nothing
-- invalidated or discarded, and a ledger that balances.
lawful ∷ InputLog → Run → Expectation
lawful log' run = do
  let report = runReport run
      records = logRecords log'
      intentions = length [() | RecordIntention {} ← records]
      controls = length records - intentions
  reportTicks report `shouldBe` ticks
  reportStatus report `shouldSatisfy` \status → status == Running || status == Paused
  -- Every record was released, to the seam the UI's path uses: none was left, and none refused.
  reportReplay report `shouldBe` Just (ReplayOutcome (length records) (length records))
  -- The log was the only source: what the session accepted and recorded is exactly the log, so no offer of the UI took a place
  -- and no request of the UI's was applied beside the log's.
  reportRecorded report `shouldBe` Right log'
  let counts = reportCounts report
  countAccepted counts `shouldBe` intentions
  (countApplied counts + countStale counts, countInvalidated counts, countDiscarded counts) `shouldBe` (intentions, 0, 0)
  controlAccepted (reportControls report) `shouldBe` controls

-- | Run a disturbance, repeated, over a log: each trace is the baseline's tick by tick, and each run is lawful.
sameUnder ∷ Disturbance → InputLog → Scenario → [Digest] → IO ()
sameUnder disturbance log' scenario baseline = replicateM_ repeats $ do
  run ← runFixed disturbance log' ticks seed scenario
  firstDivergence (traceOf run) baseline `shouldBe` Nothing
  length (traceOf run) `shouldBe` fromIntegral ticks + 1
  lawful log' run

-- | The numbers that vary from tick to tick in the logs the examples use are fixed: both are made, once, by hand.
data Fixture = Fixture
  { logPlain ∷ InputLog
  , logPausing ∷ InputLog
  , baselinePlain ∷ [Digest]
  , baselinePausing ∷ [Digest]
  }

spec ∷ Spec
spec = describe "D-23 qualified on the sample" $ do
  it "makes the same log from the same hand-driven session every time" $ do
    first ← generateLog seed ticks True
    second ← generateLog seed ticks True
    first `shouldBe` second
    length (logRecords first) `shouldSatisfy` (> fromIntegral ticks)

  beforeAll
    ( do
        plain ← generateLog seed ticks False
        pausing ← generateLog seed ticks True
        a ← runFixed undisturbed plain ticks seed Normal
        b ← runFixed undisturbed pausing ticks seed Pause
        pure (Fixture plain pausing (traceOf a) (traceOf b))
    )
    $ do
      describe "the digest trace, with the log, the seed and the configuration held fixed" $ do
        it "is identical across repeated undisturbed runs, tick by tick" $ \fixture →
          sameUnder undisturbed (logPlain fixture) Normal (baselinePlain fixture)

        it "is the same when gameplay's own behavior is the production one with a line run first in every update, which is what the disturbances use" $ \fixture →
          sameUnder undisturbed {disturbanceAdjust = \_ config → config {configGameplaySource = gameplayWith []}} (logPlain fixture) Normal (baselinePlain fixture)

        it "is identical when gameplay segments are held and released at differing points by gates" $ \fixture →
          sameUnder gated (logPlain fixture) Normal (baselinePlain fixture)

        it "is identical when segments do differing amounts of spin work" $ \fixture →
          forM_ [0, 13, 29] $ \salt → sameUnder (spun salt) (logPlain fixture) Normal (baselinePlain fixture)

        it "is identical when the UI does many more updates, snapshot reads, random draws and offered intentions of its own that are no part of the log" $ \fixture → do
          sameUnder uiHeavy (logPlain fixture) Normal (baselinePlain fixture)
          -- What the UI offered was declined before it took a place, and what it asked of gameplay was refused.
          run ← runFixed uiHeavy (logPlain fixture) ticks seed Normal
          let report = runReport run
          reportUiUpdates report `shouldSatisfy` (>= 6 * fromIntegral ticks)
          countDeclined (reportCounts report) `shouldSatisfy` (> 0)
          Map.lookup "unassigned" (controlRefused (reportControls report)) `shouldSatisfy` maybe False (> 0)
          controlAccepted (reportControls report) `shouldBe` 0

        it "is identical when the driver issues grants back to back and when it leaves gaps between them" $ \fixture → do
          sameUnder undisturbed (logPlain fixture) Normal (baselinePlain fixture)
          sameUnder gapped (logPlain fixture) Normal (baselinePlain fixture)

        it "is identical with the UI owner on the real clock and timer offering its own input and asking for its own controls" $ \fixture →
          replicateM_ 3 $ do
            run ← runFixedReal True (logPlain fixture) ticks seed Normal
            firstDivergence (traceOf run) (baselinePlain fixture) `shouldBe` Nothing
            lawful (logPlain fixture) run
            countDeclined (reportCounts (runReport run)) `shouldSatisfy` (> 0)

        it "is identical when the log a UI-driven run recorded is replayed with no UI activity at all" $ \_ →
          replicateM_ 3 $ do
            (live, recorded) ← runLive ticks seed
            case recorded of
              Left problem → expectationFailure ("the live run left no log: " <> show problem)
              Right log' → do
                -- The UI offered, and gameplay accepted, something to record.
                length (logRecords log') `shouldSatisfy` (> 0)
                replayed ← runFixed undisturbed log' ticks seed Normal
                firstDivergence (traceOf replayed) (traceOf live) `shouldBe` Nothing
                reportDigest (runReport replayed) `shouldBe` reportDigest (runReport live)
                lawful log' replayed
                reportUiUpdates (runReport replayed) `shouldBe` 0
                countDeclined (reportCounts (runReport replayed)) `shouldBe` 0

      describe "the negative controls" $ do
        it "diverge at the first tick: a different seed gives a different initial state" $ \fixture → do
          run ← runFixed undisturbed (logPlain fixture) ticks (seed + 1) Normal
          firstDivergence (traceOf run) (baselinePlain fixture) `shouldBe` Just 0

        it "diverge at the tick a record was moved from, when one record is moved to another tick" $ \fixture → do
          let moved = moveRecord 7 12 (logPlain fixture)
          moved `shouldNotBe` logPlain fixture
          length (logRecords moved) `shouldBe` length (logRecords (logPlain fixture))
          run ← runFixed undisturbed moved ticks seed Normal
          firstDivergence (traceOf run) (baselinePlain fixture) `shouldBe` Just 7

        it "diverge at the tick, when two intentions on one entity in the same tick are exchanged in place order" $ \fixture → do
          let exchanged = exchangePlaces 2 (logPlain fixture)
          exchanged `shouldNotBe` logPlain fixture
          run ← runFixed undisturbed exchanged ticks seed Normal
          firstDivergence (traceOf run) (baselinePlain fixture) `shouldBe` Just 2

        it "diverge at the tick a control applies at, when the controls of a log are left out" $ \fixture → do
          let without = logOf [record | record ← logRecords (logPausing fixture), not (isControl record)]
          run ← runFixed undisturbed without ticks seed Pause
          firstDivergence (traceOf run) (baselinePausing fixture) `shouldBe` Just 5

      describe "the pause scenario, with the controls in the log" $
        it "reproduces its trace across replays, disturbed or not, and applies exactly the controls the log holds" $ \fixture → do
          let check run = do
                controlApplied (reportControls (runReport run)) `shouldBe` 2
                controlAbandoned (reportControls (runReport run)) `shouldBe` 0
          -- Gameplay's behavior is paused for ticks five to ten (the tick that resumes it runs no update either), and a tick
          -- that runs none reaches no gate: the gated runs hold the ticks that do.
          forM_ [undisturbed, gatedOn runsUpdate, uiHeavyOn runsUpdate, spun 5, gapped] $ \disturbance →
            replicateM_ repeats $ do
              run ← runFixed disturbance (logPausing fixture) ticks seed Pause
              firstDivergence (traceOf run) (baselinePausing fixture) `shouldBe` Nothing
              lawful (logPausing fixture) run
              check run
          run ← runFixed (uiHeavyOn runsUpdate) (logPausing fixture) ticks seed Pause
          -- The UI's own requests to pause were refused before they took a place; the log's two were the only ones accepted.
          Map.lookup "unassigned" (controlRefused (reportControls (runReport run))) `shouldSatisfy` maybe False (> 0)
          real ← runFixedReal True (logPausing fixture) ticks seed Pause
          firstDivergence (traceOf real) (baselinePausing fixture) `shouldBe` Nothing
          lawful (logPausing fixture) real

      describe "the failure scenario, whose gameplay raises in tick six" $
        it "reproduces its trace, its final digest and its failure across replays, disturbed or not, and is never a complete replay" $ \fixture → do
          let log' = logPlain fixture
          baseline ← runFixed undisturbed log' ticks seed Failure
          let reference = runReport baseline
          length (reportTrace reference) `shouldBe` 6
          reportTicks reference `shouldBe` 5
          case reportStatus reference of
            Failed found → (failTick (evidencePrimary found), evidenceLater found) `shouldBe` (6, 0)
            other → expectationFailure ("expected a failed session, found " <> show other)
          let released = logOf [record | record ← logRecords log', recordTickOf record <= 6]
          forM_ [undisturbed, gapped] $ \disturbance →
            replicateM_ repeats $ do
              run ← runFixed disturbance log' ticks seed Failure
              let report = runReport run
              firstDivergence (traceOf run) (reportTrace reference) `shouldBe` Nothing
              reportDigest report `shouldBe` reportDigest reference
              reportStatus report `shouldBe` reportStatus reference
              -- Tick six's own records were released before it began and are invalidated by its failure; those of the ticks that
              -- never began were never released: the log is still the only source, and is never reported as replayed in full.
              reportRecorded report `shouldBe` Right released
              countInvalidated (reportCounts report) `shouldBe` length (recordsAt 6 log')
              replayFed' report `shouldSatisfy` \fed → fed < length (logRecords log')
              filter ("replay: " `Text.isPrefixOf`) (renderReport report) `shouldSatisfy` \found → case found of
                [line] → "incomplete (session failed at tick 6)" `Text.isSuffixOf` line
                _ → False
          real ← runFixedReal False log' ticks seed Failure
          firstDivergence (traceOf real) (reportTrace reference) `shouldBe` Nothing
          reportDigest (runReport real) `shouldBe` reportDigest reference
  where
    runsUpdate tick = tick < 5 || tick > 10
    isControl = \case
      RecordControl {} → True
      _ → False
    recordTickOf = \case
      RecordIntention place _ _ _ _ _ _ → placeTick place
      RecordControl tick _ _ _ → tick
    replayFed' report = maybe 0 replayFed (reportReplay report)
