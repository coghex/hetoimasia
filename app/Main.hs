module Main (main) where

import Hetoimasia.Foundation.Log (LogLevel (Info), handleLogger, logMessage)
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

smoke ∷ IO ()
smoke = do
  let logger = handleLogger Info stderr
  runApplication logger "hetoimasia" $
    logMessage logger Info "console" "Hello from Hetoimasia."
