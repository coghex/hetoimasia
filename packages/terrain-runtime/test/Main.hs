module Main (main) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Data.Maybe (fromMaybe)
import GHC.Conc (getNumProcessors)
import System.Environment (getArgs, withArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Test.TerrainRuntime.Capabilities (resolvePassFromEnvironment)
import qualified Test.TerrainRuntime.CapabilityControl as CapabilityControl
import Test.Hspec.Runner (Config (..), evaluateSummary, runSpec)
import Test.TerrainRuntime.Output (globalOutput, printLine)
import Test.TerrainRuntime.Runner (defaultJobs, suiteConfig)
import qualified Test.TerrainRuntime.Spec as Spec

-- | The runner's concurrency is the number of parallel jobs: at most eight, and no more than the processors; @--jobs N@ on
-- the command line replaces it. The capability count is made equal to it for the parallel group, which is first in the tree
-- ("Test.TerrainRuntime.Parallel"); the spec returns to one capability before every sequential example
-- ("Test.TerrainRuntime.Isolation"). The concurrent set runs once more, last, on the multi-capability pass's count
-- ("Test.TerrainRuntime.Concurrent"): one setting, read here before anything changes the capability count, from
-- @HETOIMASIA_CONCURRENT_PASS_CAPABILITIES@, else from the count the process started with when it is 2 or more (the lab's
-- @--rts-capabilities@ passes @+RTS -N<k>@), else 2 ("Test.TerrainRuntime.Capabilities"); a count below 2 or not a number ends the run
-- with status 2 before any example. The unchanged catalog command (@cabal test ... terrain-runtime-tests@) selects these
-- defaults; the run prints what it used. The formatter and every printed line share one lock
-- ("Test.TerrainRuntime.Output"), and the configuration is built by "Test.TerrainRuntime.Runner", which the oracle of the
-- printed lines runs as well.
main ∷ IO ()
main = do
  args0 ← getArgs
  case args0 of
    "--capability-control" : rest → control rest
    _ → suite

-- | The control of the multi-capability pass, by hand and in no routine group: @terrain-runtime-tests --capability-control@ with
-- the RTS option of the capability count ("Test.TerrainRuntime.CapabilityControl").
control ∷ [String] → IO ()
control rest = do
  config ← suiteConfig globalOutput rest
  summary ← withArgs [] (runSpec CapabilityControl.spec config {configConcurrentJobs = Just 1})
  evaluateSummary summary

suite ∷ IO ()
suite = do
  processors ← getNumProcessors
  startCaps ← getNumCapabilities
  args ← getArgs
  defaults ← defaultJobs
  pass ← resolvePassFromEnvironment startCaps >>= either refuse pure
  config ← suiteConfig globalOutput args
  let jobs = max 1 (fromMaybe 1 (configConcurrentJobs config))
  setNumCapabilities jobs
  printLine ("RUNNER jobs=" <> show jobs <> " capabilities=" <> show jobs <> " (at start " <> show startCaps <> ", processors " <> show processors <> ", default jobs " <> show defaults <> ")")
  summary ← withArgs [] (runSpec (Spec.spec pass) config)
  evaluateSummary summary
  where
    refuse why = hPutStrLn stderr ("terrain-runtime-tests: " <> why) >> exitWith (ExitFailure 2)
