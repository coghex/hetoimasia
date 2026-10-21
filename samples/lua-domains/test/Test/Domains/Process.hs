-- | The executable run as a child process (#498 requirement 13, extended by #499 requirement 13): its report for
-- each of the five scenarios, its exit status for each (0 when the session ended without a failure and a stop is not
-- one, 1 when the gameplay session failed or a UI failure was recorded, 2 for a usage error), and @--help@. It is
-- reached through this suite's @build-tool-depends@ on it, the only way anything launches it, and each child is
-- bounded. The report's UI-timing numbers are asserted on structure only.
module Test.Domains.Process (spec) where

import Data.List (isPrefixOf)
import qualified Data.Text as Text
import System.Directory (findExecutable)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Domains.Support (generous)
import Test.Hspec

run ∷ [String] → IO (ExitCode, String, String)
run arguments = do
  executable ← findExecutable "hetoimasia-lua-domains" >>= maybe (fail "the executable is not on this test's search path") pure
  generous (readCreateProcessWithExitCode (proc executable arguments) "")

-- | The report of a scenario: its lines, which the report keeps to ten.
reportOf ∷ [String] → IO (ExitCode, [String])
reportOf arguments = do
  (status, out, err) ← run arguments
  err `shouldBe` ""
  pure (status, lines out)

-- | The number that follows a marker in a line.
numberAfter ∷ String → String → Int
numberAfter marker line =
  let rest = snd (Text.breakOn (Text.pack marker) (Text.pack line))
   in read (Text.unpack (Text.takeWhile (`elem` ['0' .. '9']) (Text.drop (length marker) rest)))

-- | What every scenario's report has in common: ten lines in a fixed order, and a ledger that balances.
structure ∷ String → [String] → Expectation
structure scenario reported = do
  length reported `shouldBe` 10
  take 1 reported `shouldBe` ["hetoimasia-lua-domains: session 1, seed 1, scenario " <> scenario]
  map (takeWhile (/= ':')) (drop 1 reported)
    `shouldBe` ["ticks committed", "status", "intentions answered", "intentions settled", "controls", "ui", "cleanup", "cleanup", "cleanup"]
  let accepted = numberAfter "accepted " (reported !! 3)
      settled = sum [numberAfter label (reported !! 4) | label ← ["applied ", "stale ", "invalidated ", "discarded "]]
  -- Every accepted intention is exactly one of applied, stale, invalidated or discarded, and none is left.
  accepted `shouldBe` settled
  reported !! 9 `shouldSatisfy` ("cleanup: workspaces acquired 1, released 1, release failed 0; publication closed; pending 0;" `isPrefixOf`)
  -- Both owners ended.
  reported !! 7 `shouldSatisfy` ("cleanup: ui ended" `isPrefixOf`)
  (reported !! 7) `shouldSatisfy` (\line → "gameplay ended" `elem` [take 14 (drop n line) | n ← [0 .. length line - 14]])

spec ∷ Spec
spec = describe "the executable" $ do
  it "runs the normal scenario, exits 0 and writes one bounded report on stdout and nothing on stderr" $ do
    (status, reported) ← reportOf ["--ticks", "20", "--seed", "1"]
    status `shouldBe` ExitSuccess
    structure "normal" reported
    reported !! 1 `shouldBe` "ticks committed: 20"
    reported !! 2 `shouldBe` "status: running"
    numberAfter "updates " (reported !! 6) `shouldSatisfy` (>= 0)

  it "commits the ticks it is asked for, at the seed it is asked for" $ do
    (status, out, _) ← run ["--ticks", "3", "--seed", "99"]
    status `shouldBe` ExitSuccess
    take 2 (lines out) `shouldBe` ["hetoimasia-lua-domains: session 1, seed 99, scenario normal", "ticks committed: 3"]

  it "runs the pause scenario, pausing and resuming gameplay once, and exits 0" $ do
    (status, reported) ← reportOf ["--scenario", "pause"]
    status `shouldBe` ExitSuccess
    structure "pause" reported
    reported !! 1 `shouldBe` "ticks committed: 20"
    -- Two controls were asked for and accepted; each was read, or abandoned when the run ended: none lost.
    let controls = reported !! 5
        accepted = numberAfter "accepted " controls
        accounted = sum [numberAfter label controls | label ← ["applied ", "already ", "no longer applicable ", "abandoned "]]
    (numberAfter "offered " controls, accepted) `shouldBe` (2, 2)
    accounted `shouldBe` accepted

  it "runs the failure scenario, whose gameplay behavior raises at tick six, and exits 1 with the failure's evidence in the report" $ do
    (status, reported) ← reportOf ["--scenario", "failure"]
    status `shouldBe` ExitFailure 1
    structure "failure" reported
    reported !! 1 `shouldBe` "ticks committed: 5"
    reported !! 2 `shouldSatisfy` ("status: failed at tick 6: gameplay active update, script error: " `isPrefixOf`)
    reported !! 2 `shouldSatisfy` (\line → "scripted failure at tick 6" `elem` [take 26 (drop n line) | n ← [0 .. length line - 26]])

  it "runs the flood scenario, which offers more intentions than the queue holds, and exits 0" $ do
    (status, reported) ← reportOf ["--scenario", "flood"]
    status `shouldBe` ExitSuccess
    structure "flood" reported
    numberAfter "full " (reported !! 3) `shouldSatisfy` (> 0)
    numberAfter "busy " (reported !! 6) `shouldSatisfy` (> 0)

  it "runs the stop scenario, which stops the session after tick eight, and exits 0: a stop is not a failure" $ do
    (status, reported) ← reportOf ["--scenario", "stop"]
    status `shouldBe` ExitSuccess
    structure "stop" reported
    reported !! 1 `shouldBe` "ticks committed: 8"
    reported !! 2 `shouldBe` "status: stopped"

  it "prints the usage on stdout for --help and exits 0" $ do
    (status, out, err) ← run ["--help"]
    status `shouldBe` ExitSuccess
    err `shouldBe` ""
    take 1 (lines out) `shouldBe` ["usage: hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME] | --help"]

  mapM_
    usageError
    [ ("an unknown argument", ["--bogus"], "unknown argument '--bogus'")
    , ("a malformed ticks value", ["--ticks", "many"], "malformed value 'many' for --ticks")
    , ("a malformed seed value", ["--seed", "-3"], "malformed value '-3' for --seed")
    , ("an unknown scenario", ["--scenario", "chaos"], "malformed value 'chaos' for --scenario")
    , ("a missing value", ["--ticks"], "missing value after --ticks")
    , ("a missing scenario", ["--scenario"], "missing value after --scenario")
    , ("a repeated option", ["--ticks", "2", "--ticks", "3"], "repeated option --ticks")
    ]

  it "escapes a forged argument, so the one line on stderr stays one line" $ do
    (status, out, err) ← run ["--x\nusage: forged"]
    status `shouldBe` ExitFailure 2
    out `shouldBe` ""
    length (lines err) `shouldBe` 1
    err `shouldSatisfy` ("hetoimasia-lua-domains: unknown argument '--x\\x0ausage: forged'" `isPrefixOf`)
  where
    usageError (label, arguments, reason) = it ("exits 2 for " <> label <> ", with one line on stderr and nothing on stdout") $ do
      (status, out, err) ← run arguments
      status `shouldBe` ExitFailure 2
      out `shouldBe` ""
      length (lines err) `shouldBe` 1
      err `shouldSatisfy` (("hetoimasia-lua-domains: " <> reason) `isPrefixOf`)
