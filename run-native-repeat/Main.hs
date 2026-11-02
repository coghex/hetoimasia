-- | The repeated-run probe of the macOS @glfwInit@ hang (#586): an optional local probe, macOS only, never selected by
-- affected inputs and routed to no CI group.
--
-- The complete @run-native-tests@ profile is run N times, one at a time, each under a bound. A run that exceeds its
-- bound is sampled once (bounded), then stopped by pid with everything it started, and counts as a hang; so does a run
-- the initialization deadline ended, even when the enclosing suite reports only a generic failure. A run counts only
-- if it ran the whole profile and passed every example. The probe reports N, the confidence that N runs would have
-- shown a failure that occurs in 5% of runs, and how many runs passed, hung and failed, and keeps every run's output
-- and sample in its output directory.
--
-- /Statistical assumption./ N independent trials at an unchanged per-run failure probability of 5% show at least one
-- failure with probability @1 - 0.95^N@; at N = 59 that is 95.15%. This is detection power, not proof that the fixed
-- program cannot hang.
--
-- /Configuration/, all by environment, none persistent:
--
-- * @HETOIMASIA_NATIVE_SESSION=desktop@, the consent the profile itself requires, on this probe's own command. The
--   probe refuses without it rather than launch runs that refuse.
-- * @HETOIMASIA_REPEAT_RUNS@, N (default 59, the least that gives 95% confidence at 5%).
-- * @HETOIMASIA_REPEAT_UNTIL_HANG=1@, for the batch at an unfixed revision: stop after the first hang (at most N
--   runs) and require one, so the probe is shown sensitive; without a hang in N runs it fails and says so.
-- * @HETOIMASIA_REPEAT_CHECKOUT@, the checkout whose prepared profile is run (default the working directory). Both
--   its suite and the product executable are built beforehand with
--   @bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests@.
-- * @HETOIMASIA_REPEAT_OUTPUT@, where each run's output, samples and the report are kept (default a new directory in
--   the temporary directory, printed).
-- * @HETOIMASIA_REPEAT_BOUND_SECONDS@, one run's bound (default 45; a healthy run takes 8 to 13 seconds).
module Main (main) where

import Control.Monad (unless, when)
import Data.List (isInfixOf)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory, withSystemTempDirectory)
import System.Info (os)
import System.Process (CreateProcess (cwd), readCreateProcessWithExitCode, shell)
import System.Timeout (timeout)
import Test.Hspec
import Test.Run.Repeat.Batch
import Text.Printf (printf)
import Text.Read (readMaybe)

main ∷ IO ()
main = hspec spec

spec ∷ Spec
spec = do
  describe "the repeated-run machinery (stub children, no native session)" machinery
  describe "the complete native profile, repeated" $
    it "runs the whole profile N times, one at a time, and reports how many passed, hung and failed" realBatch

-- ---------------------------------------------------------------------------
-- Stub children

-- | A trial over a shell script standing for the profile, with a sampler that writes a file.
stub ∷ FilePath → Int → String → Trial
stub directory bound script =
  Trial
    { trialCommand = ["/bin/sh", "-c", script]
    , trialDirectory = directory
    , trialBoundSeconds = bound
    , trialSample = \pid file → ["/bin/sh", "-c", "echo sampled " <> show pid <> " > " <> file]
    , trialExpectedExamples = 54
    , trialSampleBoundSeconds = 5
    , trialStopGraceSeconds = 5
    }

machinery ∷ Spec
machinery = do
  it "counts a run that ran every example and exited 0 as passed" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      outcome ← runTrial (stub directory 30 "echo '54 examples, 0 failures'") directory 1
      outcomeVerdict outcome `shouldBe` Passed
      outcomeStatus outcome `shouldBe` Just ExitSuccess
      outcomeReclaimed outcome `shouldBe` True

  it "does not count a run that ran fewer examples than the profile has" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      outcome ← runTrial (stub directory 30 "echo '12 examples, 0 failures'") directory 1
      outcomeVerdict outcome `shouldSatisfy` isFailed

  it "counts a run that exited non-zero without a hang marker as failed" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      outcome ← runTrial (stub directory 30 "echo '54 examples, 1 failure' ; exit 1") directory 1
      outcomeVerdict outcome `shouldSatisfy` isFailed

  it "counts a run the initialization deadline ended inside a child as a hang, though the suite reports a generic failure" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      outcome ← runTrial (stub directory 30 "echo 'native initialization exceeded its bound; ending the process' >&2; echo '54 examples, 1 failures'; exit 1") directory 1
      outcomeVerdict outcome `shouldSatisfy` isHung
      outcomeSamples outcome `shouldBe` []

  it "counts the deadline's own exit status as a hang" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      outcome ← runTrial (stub directory 30 "exit 75") directory 1
      outcomeVerdict outcome `shouldSatisfy` isHung

  it "samples a run that exceeds its bound once per process, then stops it and everything it started" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let pidFile = directory </> "grandchild.pid"
      outcome ← runTrial (stub directory 2 ("sleep 3600 & echo $! > " <> pidFile <> "; wait")) directory 1
      outcomeVerdict outcome `shouldSatisfy` isHung
      outcomeStatus outcome `shouldBe` Nothing
      length (outcomeSamples outcome) `shouldSatisfy` (>= 2)
      outcomeSamples outcome `shouldSatisfy` all ("sample.txt" `isInfixOf`)
      outcomeReclaimed outcome `shouldBe` True
      grandchild ← readFile pidFile
      case readMaybe grandchild of
        Nothing → expectationFailure ("no grandchild pid: " <> grandchild)
        Just pid → isAlive pid `shouldReturn` False

  it "bounds a sample that never finishes, records that no sample was taken, and still stops the run" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let trial = (stub directory 2 "sleep 3600") {trialSample = \_ _ → ["/bin/sh", "-c", "sleep 3600"], trialSampleBoundSeconds = 1}
      outcome ← runTrial trial directory 1
      outcomeVerdict outcome `shouldSatisfy` isHung
      outcomeSamples outcome `shouldSatisfy` all ("exceeded its bound" `isInfixOf`)
      outcomeReclaimed outcome `shouldBe` True

  it "stops what a run started when the run is cancelled" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let pidFile = directory </> "grandchild.pid"
      -- The outer bound abandons the trial while it waits; nothing it started may outlive that.
      abandoned ← timeout 1_500_000 (runTrial (stub directory 600 ("sleep 3600 & echo $! > " <> pidFile <> "; wait")) directory 1)
      abandoned `shouldSatisfy` maybe True (const False)
      grandchild ← readFile pidFile
      case readMaybe grandchild of
        Nothing → expectationFailure ("no grandchild pid: " <> grandchild)
        Just pid → isAlive pid `shouldReturn` False

  it "stops a child a passing run left behind, counts it, and does not report the run as clean" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let pidFile = directory </> "orphan.pid"
      outcome ← runTrial (stub directory 30 ("sleep 3600 & echo $! > " <> pidFile <> "; echo '54 examples, 0 failures'")) directory 1
      outcomeVerdict outcome `shouldBe` Passed
      outcomeOrphans outcome `shouldSatisfy` (>= 1)
      outcomeReclaimed outcome `shouldBe` True
      orphan ← readFile pidFile
      case readMaybe orphan of
        Nothing → expectationFailure ("no orphan pid: " <> orphan)
        Just pid → isAlive pid `shouldReturn` False

  it "stops a sampler that ignores TERM and has outlived its bound, and reaps it before the run goes on" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let pidFile = directory </> "sampler.pid"
          sampler = ["/bin/sh", "-c", "trap '' TERM; echo $$ > " <> pidFile <> "; while :; do sleep 1; done"]
          trial = (stub directory 2 "sleep 3600") {trialSample = \_ _ → sampler, trialSampleBoundSeconds = 1, trialStopGraceSeconds = 2}
      outcome ← runTrial trial directory 1
      outcomeVerdict outcome `shouldSatisfy` isHung
      outcomeSamples outcome `shouldSatisfy` all ("sampler was stopped" `isInfixOf`)
      outcomeReclaimed outcome `shouldBe` True
      sampler' ← readFile pidFile
      case readMaybe sampler' of
        Nothing → expectationFailure ("no sampler pid: " <> sampler')
        Just pid → isAlive pid `shouldReturn` False

  it "persists the partial report, with the interrupted attempt recorded as a failure, when a batch is cancelled" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let render outcomes = show (length outcomes) <> " attempts, " <> show (map outcomeVerdict outcomes)
          trial = stub directory 600 "sleep 3600"
      abandoned ← timeout 1_500_000 (runBatch trial directory 3 False render (\_ _ → pure ()))
      abandoned `shouldSatisfy` maybe True (const False)
      report ← readFile (directory </> "report.md")
      report `shouldSatisfy` ("1 attempts" `isInfixOf`)
      report `shouldSatisfy` ("interrupted" `isInfixOf`)

  it "writes the report after every trial and stops a batch exactly when it should" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      outcomes ← runBatch (stub directory 30 "echo '54 examples, 0 failures'") directory 3 False (show . map outcomeVerdict) (\_ _ → pure ())
      length outcomes `shouldBe` 3
      readFile (directory </> "report.md") >>= (`shouldBe` show [Passed, Passed, Passed])
      let clean = Outcome Passed (Just ExitSuccess) 0 [] True 0
          unreclaimed = clean {outcomeReclaimed = False}
          hangs = clean {outcomeVerdict = Hung "x"}
      continues 3 1 False clean `shouldBe` True
      continues 3 3 False clean `shouldBe` False
      continues 3 1 True hangs `shouldBe` False
      continues 3 1 False hangs `shouldBe` True
      continues 3 1 False unreclaimed `shouldBe` False

  it "runs a preparation to completion with its output kept, and answers how it ended" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      ended ← runPreparation ["/bin/sh", "-c", "echo built; echo warned >&2; exit 3"] directory (directory </> "prepare.out") 30 5
      ended `shouldBe` Just (ExitFailure 3)
      readFile (directory </> "prepare.out") >>= (`shouldSatisfy` \kept → "built" `isInfixOf` kept && "warned" `isInfixOf` kept)

  it "stops a preparation that exceeds its bound, and everything it started" $
    withSystemTempDirectory "repeat-probe" $ \directory → do
      let pidFile = directory </> "grandchild.pid"
      ended ← runPreparation ["/bin/sh", "-c", "sleep 3600 & echo $! > " <> pidFile <> "; wait"] directory (directory </> "prepare.out") 2 5
      ended `shouldBe` Nothing
      grandchild ← readFile pidFile
      case readMaybe grandchild of
        Nothing → expectationFailure ("no grandchild pid: " <> grandchild)
        Just pid → isAlive pid `shouldReturn` False

  it "states the confidence of a batch from its size" $ do
    confidenceAt 0.05 59 `shouldSatisfy` (\c → abs (c - 0.9515) < 0.0001)
    confidenceAt 0.05 58 `shouldSatisfy` (< 0.95)
    tally [Outcome Passed Nothing 0 [] True 0, Outcome (Hung "x") Nothing 0 [] True 0, Outcome (Failed "y") Nothing 0 [] True 0]
      `shouldBe` Counts {passed = 1, hung = 1, failed = 1}
  where
    isFailed (Failed _) = True
    isFailed _ = False
    isHung (Hung _) = True
    isHung _ = False

-- ---------------------------------------------------------------------------
-- The real batch

realBatch ∷ Expectation
realBatch = do
  when (os /= "darwin") $ expectationFailure "this probe is macOS only"
  consent ← lookupEnv "HETOIMASIA_NATIVE_SESSION"
  unless (consent == Just "desktop") $
    expectationFailure "the complete profile needs HETOIMASIA_NATIVE_SESSION=desktop on this probe's own command (AGENTS.md, standing approval)"
  runs ← maybe 59 id . (>>= readMaybe) <$> lookupEnv "HETOIMASIA_REPEAT_RUNS"
  untilHang ← (== Just "1") <$> lookupEnv "HETOIMASIA_REPEAT_UNTIL_HANG"
  bound ← maybe 45 id . (>>= readMaybe) <$> lookupEnv "HETOIMASIA_REPEAT_BOUND_SECONDS"
  checkout ← lookupEnv "HETOIMASIA_REPEAT_CHECKOUT" >>= maybe getCurrentDirectory pure
  output ← lookupEnv "HETOIMASIA_REPEAT_OUTPUT" >>= maybe fresh pure
  createDirectoryIfMissing True output
  revision ← command checkout "git rev-parse HEAD"
  -- Both the suite and the product executable are built for this revision before its batch: the runner reports checkout
  -- provenance and checks that the binaries exist, and does not rebuild them, so a stale binary would otherwise be measured as
  -- this revision. The build's output is kept beside the runs'.
  prepared ←
    runPreparation
      ["bash", "tools/vulkan/run.sh", "build", "hetoimasia:exe:hetoimasia", "hetoimasia:test:run-native-tests"]
      checkout
      (output </> "prepare.out")
      3600
      10
  prepared `shouldBe` Just ExitSuccess
  let trial =
        Trial
          { trialCommand = ["bash", "tools/vulkan/run.sh", "native", "hetoimasia:test:run-native-tests", "--", "--complete"]
          , trialDirectory = checkout
          , trialBoundSeconds = bound
          , trialSample = \pid file → ["sample", show pid, "5", "-file", file]
          , trialExpectedExamples = 54
          , trialSampleBoundSeconds = 30
          , trialStopGraceSeconds = 10
          }
  outcomes ←
    runBatch trial output runs untilHang (Text.unpack . reportOf runs untilHang revision checkout output) $ \index outcome →
      Text.putStrLn . Text.pack $
        (printf "run %d/%d: %s in %.1f s%s" index runs (verdictWord (outcomeVerdict outcome)) (outcomeSeconds outcome) (reasonOf outcome) ∷ String)
  let counts = tally outcomes
      attempted = length outcomes
      report = reportOf runs untilHang revision checkout output outcomes
  Text.putStrLn report
  unless (all outcomeReclaimed outcomes) $
    expectationFailure "a run's processes could not all be stopped; the batch stopped there rather than start another beside them"
  if untilHang
    then hung counts `shouldSatisfy` (>= 1)
    else do
      attempted `shouldBe` runs
      counts `shouldBe` Counts {passed = runs, hung = 0, failed = 0}
  where
    fresh = do
      temporary ← getCanonicalTemporaryDirectory
      createTempDirectory temporary "hetoimasia-repeat-"
    command ∷ FilePath → String → IO String
    command directory line = do
      (_, out, _) ← readCreateProcessWithExitCode ((shell line) {cwd = Just directory}) ""
      pure (filter (/= '\n') out)
    verdictWord ∷ Verdict → String
    verdictWord Passed = "passed"
    verdictWord (Hung _) = "HUNG"
    verdictWord (Failed _) = "FAILED"
    reasonOf ∷ Outcome → String
    reasonOf outcome = case outcomeVerdict outcome of
      Passed → ""
      Hung why → " (" <> why <> ")"
      Failed why → " (" <> why <> ")"

reportOf ∷ Int → Bool → String → FilePath → FilePath → [Outcome] → Text.Text
reportOf runs untilHang revision checkout output outcomes =
  Text.pack . unlines $
    [ "# Repeated complete run-native-tests profile (#586)"
    , ""
    , "- revision: " <> revision
    , "- checkout: " <> checkout
    , "- output: " <> output
    , "- mode: " <> (if untilHang then "until the first hang (unfixed revision)" else "N consecutive runs (fixed revision)")
    , printf "- N: %d planned, %d attempted" runs (length outcomes)
    , printf
        "- confidence: N = %d independent runs at an unchanged 5%% per-run failure probability would have shown at least one failure with probability %.2f%% (1 - 0.95^N); this is detection power, not proof that the program cannot hang"
        runs
        (100 * confidenceAt 0.05 runs)
    , printf "- passed: %d, hung: %d, failed: %d (an interrupted attempt counts as a failure)" (passed counts) (hung counts) (failed counts)
    , "- a run the initialization deadline ended counts as a hang, not a pass"
    , ""
    , "## Hangs"
    ]
      <> [ printf "- run %d: %s; samples: %s; everything it started stopped: %s" (index ∷ Int) why (show (outcomeSamples outcome)) (show (outcomeReclaimed outcome))
         | (index, outcome) ← zip [1 ..] outcomes
         , Hung why ← [outcomeVerdict outcome]
         ]
      <> ["", "## Failures"]
      <> [ printf "- run %d: %s" (index ∷ Int) why
         | (index, outcome) ← zip [1 ..] outcomes
         , Failed why ← [outcomeVerdict outcome]
         ]
      <> ["", "## Processes left behind by a run that ended on its own"]
      <> [ printf "- run %d: %d, stopped" (index ∷ Int) (outcomeOrphans outcome)
         | (index, outcome) ← zip [1 ..] outcomes
         , outcomeOrphans outcome > 0
         ]
  where
    counts = tally outcomes
