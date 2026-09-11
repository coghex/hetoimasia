module Main (main) where

import Hetoimasia.Foundation.Log
  ( Component
  , defaultLogFilter
  , handleLogger
  , logInfo
  , unsafeComponent
  )
import Hetoimasia.Runtime (runApplication)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (stderr)

main ∷ IO ()
main = do
  args ← getArgs
  case args of
    [] → smoke
    ["--smoke"] → smoke
    ["--help"] → putStrLn "Usage: hetoimasia [--smoke | --help]"
    _ → die "Usage: hetoimasia [--smoke | --help]"

-- | The component this executable's own entries use.
consoleComponent ∷ Component
consoleComponent = unsafeComponent "console"

-- | @stderr@ is this process's, not the logger's: the sink borrows it, and the
-- runtime scope holding it outlives every entry written through it.
smoke ∷ IO ()
smoke = do
  logger ← handleLogger defaultLogFilter stderr
  runApplication logger "hetoimasia" $
    logInfo logger consoleComponent "Hello from Hetoimasia." []
