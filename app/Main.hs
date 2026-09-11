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

smoke ∷ IO ()
smoke = do
  let logger = handleLogger defaultLogFilter stderr
  runApplication logger "hetoimasia" $
    logInfo logger consoleComponent "Hello from Hetoimasia." []
