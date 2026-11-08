-- | The offline @terrain-mapgen@ tool (TRA-14): a thin shell over
-- "Hetoimasia.Terrain.MapGen.Cli". It performs the printing and the exit; every
-- decision is in the library, where the tests drive it.
module Main (main) where

import Hetoimasia.Terrain.MapGen.Cli (Outcome (..), runCli)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

main ∷ IO ()
main = do
  arguments ← getArgs
  outcome ← runCli arguments
  mapM_ putStrLn (outcomeOut outcome)
  mapM_ (hPutStrLn stderr) (outcomeErr outcome)
  exitWith (if outcomeExit outcome == 0 then ExitSuccess else ExitFailure (outcomeExit outcome))
