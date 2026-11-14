-- | The runner configuration every executable of this package runs its spec with: Hspec's own, with the processor-count job
-- default ("Test.TerrainRuntime.Parallel") and every formatter guarded by the output lock
-- ("Test.TerrainRuntime.Output"). 'Main', the full-depth probe and the oracle of the printed lines
-- ("Test.TerrainRuntime.OutputSpec") all build their configuration here, so what the oracle runs is what the suite runs. The
-- storage probe, a separate local probe of #663's work, keeps its own plain runner.
module Test.TerrainRuntime.Runner
  ( suiteConfig
  , pinnedConfig
  , runSuite
  , defaultJobs
  ) where

import GHC.Conc (getNumProcessors)
import System.Environment (getArgs, withArgs)
import Test.Hspec (Spec)
import Test.Hspec.Runner (ColorMode (..), Config (..), UnicodeMode (..), defaultConfig, evaluateSummary, readConfig, runSpec)
import Test.TerrainRuntime.Output (Output, globalOutput, guardFormatters)

-- | The runner's concurrency when the command line does not say: the number of processors, and at most eight.
defaultJobs ∷ IO Int
defaultJobs = min 8 <$> getNumProcessors

-- | The defaults every run starts from: the processor-count job default and the formatters guarded by the output's lock.
baseConfig ∷ Output → IO Config
baseConfig out = do
  jobs ← defaultJobs
  pure (guardFormatters out defaultConfig {configConcurrentJobs = Just jobs})

-- | The configuration for a command line: the defaults, then Hspec's own reading of the arguments (@--jobs N@,
-- @--format NAME@, @--match@, and the rest) and of what @readConfig@ reads besides them: the @.hspec@ files of the home and
-- the working directory, @HSPEC_OPTIONS@ and every @HSPEC_*@ variable. This is what @Main@ runs with.
suiteConfig ∷ Output → [String] → IO Config
suiteConfig out args = baseConfig out >>= \base → readConfig base args

-- | The same defaults with nothing taken from the environment: no @.hspec@ file, no @HSPEC_*@ variable, no
-- command line. The oracle of the printed lines ("Test.TerrainRuntime.OutputSpec") runs a nested spec with it, because the
-- text a formatter writes depends on all of those (colour, unicode, the formatter itself, the job count) and the oracle must
-- not pass or fail by the environment it happens to run in. The formatter is named, the colour mode is explicit (what
-- GitHub Actions does is the colour-on case), unicode is off (the symbols are ASCII whatever the locale), the job count is
-- given. Two inputs @runSpec@ reads itself stay with the caller, who pins them: @GITHUB_ACTIONS@ and @BUILDKITE@ (they turn
-- Hspec's progress text off when colour is forced) and the handle's encoding.
pinnedConfig ∷ Output → String → Bool → Int → IO Config
pinnedConfig out formatter colour jobs = do
  base ← baseConfig out
  pure base
    { configFormat = lookup formatter (configAvailableFormatters base)
    , configColorMode = if colour then ColorAlways else ColorNever
    , configUnicodeMode = UnicodeNever
    , configConcurrentJobs = Just jobs
    }

-- | Run a spec the way every executable of the package does and exit with its result.
runSuite ∷ Spec → IO ()
runSuite spec = do
  args ← getArgs
  config ← suiteConfig globalOutput args
  summary ← withArgs [] (runSpec spec config)
  evaluateSummary summary
