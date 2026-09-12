module Main (main) where

import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Hetoimasia.Foundation.Log
  ( Component
  , LogFilter
  , LogVariables (..)
  , defaultLogFilter
  , handleLogger
  , logInfo
  , resolveLogFilter
  , unsafeComponent
  )
import Hetoimasia.Runtime (runApplication)
import Hetoimasia.Runtime.Resources (resourceSmoke, smokeWork, workingReleases)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.IO (stderr)

-- | Startup resolves the logging configuration before any supported path
-- runs, so a present but invalid variable fails with a non-zero exit and a
-- message on stderr naming it — before any entry is emitted and before the
-- application action runs.
main ∷ IO ()
main = do
  configuration ← resolveLogFilter logVariables readVariable defaultLogFilter
  logFilter ← either (die . Text.unpack) pure configuration
  args ← getArgs
  case args of
    [] → smoke logFilter
    ["--smoke"] → smoke logFilter
    ["--resource-smoke"] → resourceSmokePath logFilter
    ["--help"] → Text.putStr help
    _ → die (Text.unpack usage)

-- | The three variables this console application reads its logging
-- configuration from. The names are this application's own choice: the
-- foundation parsers and 'resolveLogFilter' take values, so another application
-- is free to use another prefix over the same contract.
logVariables ∷ LogVariables
logVariables = LogVariables
  { variableGlobalLevel = "HETOIMASIA_LOG_LEVEL"
  , variableComponentLevels = "HETOIMASIA_LOG_LEVELS"
  , variableDebug = "HETOIMASIA_DEBUG"
  }

-- | The environment access 'resolveLogFilter' is given: one lookup per
-- variable, and nothing reads the environment again afterwards.
readVariable ∷ Text → IO (Maybe Text)
readVariable name = fmap Text.pack <$> lookupEnv (Text.unpack name)

-- | Help and usage are ordinary application output rather than diagnostics, so
-- they go to stdout and stay visible at any configured threshold.
usage ∷ Text
usage = "Usage: hetoimasia [--smoke | --resource-smoke | --help]"

help ∷ Text
help = Text.unlines
  [ usage
  , ""
  , "  --smoke           Log one entry through the runtime and exit."
  , "  --resource-smoke  Own a workspace and a composite channel through the"
  , "                    resource scopes, do bounded work with them, and report"
  , "                    the lifecycle. See docs/resources.md, Application"
  , "                    lifecycle."
  , ""
  , "Logging is configured from the environment, read once at startup. An"
  , "absent variable keeps its default; a present but invalid value fails"
  , "startup with a non-zero exit and a message on stderr naming it."
  , ""
  , "  HETOIMASIA_LOG_LEVEL   Global threshold for components without an"
  , "                         override: debug, info, warn, warning, or error,"
  , "                         case-insensitively. Default: info."
  , "  HETOIMASIA_LOG_LEVELS  Exact per-component thresholds, as a"
  , "                         comma-separated list of component=level pairs"
  , "                         such as gpu.vulkan=warn,lua=info."
  , "                         Default: no overrides."
  , "  HETOIMASIA_DEBUG       Which components may emit Debug: none, all, or a"
  , "                         comma-separated component list such as"
  , "                         gpu.vulkan,lua. Default: none."
  , ""
  , "A threshold never enables Debug, and HETOIMASIA_DEBUG is the only control"
  , "that does. The master and source switches stay programmatic."
  ]

-- | The component this executable's own entries use.
consoleComponent ∷ Component
consoleComponent = unsafeComponent "console"

-- | @stderr@ is this process's, not the logger's: the sink borrows it, and the
-- runtime scope holding it outlives every entry written through it.
smoke ∷ LogFilter → IO ()
smoke configuration = do
  logger ← handleLogger configuration stderr
  runApplication logger "hetoimasia" $
    logInfo logger consoleComponent "Hello from Hetoimasia." []

-- | The owned-resource path. It borrows @stderr@ exactly as 'smoke' does, and
-- the work and the cleanup outcomes are the module's own defaults, so what this
-- executable runs is the same body the suite drives with failures injected.
--
-- 'resourceSmoke' returns the work's result and this path has nothing to do
-- with it: the demonstration's output is its diagnostics, and stdout stays
-- empty.
resourceSmokePath ∷ LogFilter → IO ()
resourceSmokePath configuration = do
  logger ← handleLogger configuration stderr
  runApplication logger "hetoimasia" $
    void (resourceSmoke logger workingReleases smokeWork)
