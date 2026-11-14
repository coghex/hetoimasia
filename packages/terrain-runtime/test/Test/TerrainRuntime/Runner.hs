-- | The runner configuration every executable of this package runs its spec with: Hspec's own, with the processor-count job
-- default ("Test.TerrainRuntime.Parallel") and every formatter guarded by the output lock
-- ("Test.TerrainRuntime.Output"). 'Main', the full-depth probe and the oracle of the printed lines
-- ("Test.TerrainRuntime.OutputSpec") all build their configuration here, so what the oracle runs is what the suite runs. The
-- storage probe, a separate local probe of #663's work, keeps its own plain runner.
module Test.TerrainRuntime.Runner
  ( suiteConfig
  , runSuite
  , defaultJobs
  ) where

import GHC.Conc (getNumProcessors)
import System.Environment (getArgs, withArgs)
import Test.Hspec (Spec)
import Test.Hspec.Runner (Config (..), defaultConfig, evaluateSummary, readConfig, runSpec)
import Test.TerrainRuntime.Output (Output, globalOutput, guardFormatters)

-- | The runner's concurrency when the command line does not say: the number of processors, and at most eight.
defaultJobs ∷ IO Int
defaultJobs = min 8 <$> getNumProcessors

-- | The configuration for a command line: the defaults, the formatters guarded by the output's lock, then Hspec's own
-- reading of the arguments (@--jobs N@, @--format NAME@, @--match@, and the rest).
suiteConfig ∷ Output → [String] → IO Config
suiteConfig out args = do
  jobs ← defaultJobs
  readConfig (guardFormatters out defaultConfig {configConcurrentJobs = Just jobs}) args

-- | Run a spec the way every executable of the package does and exit with its result.
runSuite ∷ Spec → IO ()
runSuite spec = do
  args ← getArgs
  config ← suiteConfig globalOutput args
  summary ← withArgs [] (runSpec spec config)
  evaluateSummary summary
