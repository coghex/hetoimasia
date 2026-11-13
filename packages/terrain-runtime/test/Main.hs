module Main (main) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Data.Maybe (fromMaybe)
import GHC.Conc (getNumProcessors)
import System.Environment (getArgs, withArgs)
import qualified Test.TerrainRuntime.Spec as Spec
import Test.Hspec.Runner (Config (..), defaultConfig, evaluateSummary, readConfig, runSpec)

-- | The runner's concurrency is the number of parallel jobs: at most eight, and no more than the processors; @--jobs N@ on
-- the command line replaces it. The capability count is made equal to it for the parallel group, which is first in the tree
-- ("Test.TerrainRuntime.Parallel"); the spec returns to one capability before every sequential example
-- ("Test.TerrainRuntime.Isolation"). The unchanged catalog command (@cabal test ... terrain-runtime-tests@) selects these
-- defaults; the run prints what it used.
main ∷ IO ()
main = do
  processors ← getNumProcessors
  startCaps ← getNumCapabilities
  args ← getArgs
  config ← readConfig defaultConfig {configConcurrentJobs = Just (min 8 processors)} args
  let jobs = max 1 (fromMaybe 1 (configConcurrentJobs config))
  setNumCapabilities jobs
  putStrLn ("RUNNER jobs=" <> show jobs <> " capabilities=" <> show jobs <> " (at start " <> show startCaps <> ", processors " <> show processors <> ", default jobs " <> show (min 8 processors) <> ")")
  summary ← withArgs [] (runSpec Spec.spec config)
  evaluateSummary summary
