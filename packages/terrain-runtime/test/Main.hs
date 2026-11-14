module Main (main) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Data.Maybe (fromMaybe)
import GHC.Conc (getNumProcessors)
import System.Environment (getArgs, withArgs)
import Test.Hspec.Runner (Config (..), evaluateSummary, runSpec)
import Test.TerrainRuntime.Output (globalOutput, printLine)
import Test.TerrainRuntime.Runner (defaultJobs, suiteConfig)
import qualified Test.TerrainRuntime.Spec as Spec

-- | The runner's concurrency is the number of parallel jobs: at most eight, and no more than the processors; @--jobs N@ on
-- the command line replaces it. The capability count is made equal to it for the parallel group, which is first in the tree
-- ("Test.TerrainRuntime.Parallel"); the spec returns to one capability before every sequential example
-- ("Test.TerrainRuntime.Isolation"). The unchanged catalog command (@cabal test ... terrain-runtime-tests@) selects these
-- defaults; the run prints what it used. The formatter and every printed line share one lock
-- ("Test.TerrainRuntime.Output"), and the configuration is built by "Test.TerrainRuntime.Runner", which the oracle of the
-- printed lines runs as well.
main ∷ IO ()
main = do
  processors ← getNumProcessors
  startCaps ← getNumCapabilities
  args ← getArgs
  defaults ← defaultJobs
  config ← suiteConfig globalOutput args
  let jobs = max 1 (fromMaybe 1 (configConcurrentJobs config))
  setNumCapabilities jobs
  printLine ("RUNNER jobs=" <> show jobs <> " capabilities=" <> show jobs <> " (at start " <> show startCaps <> ", processors " <> show processors <> ", default jobs " <> show defaults <> ")")
  summary ← withArgs [] (runSpec Spec.spec config)
  evaluateSummary summary
