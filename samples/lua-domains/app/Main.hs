-- | @hetoimasia-lua-domains [--ticks N] [--seed N]@: a headless session of a UI Lua VM owner and a
-- gameplay Lua VM owner against a fixed scripted fake input source.
--
-- It commits N ticks (twenty by default), retires both owners, and exits 0 after one bounded
-- report on stdout. @--help@ prints the usage and exits 0. Any unknown or malformed argument
-- prints one bounded usage line on stderr and exits 2. Diagnostics go to stderr, and no window is
-- created. A failure of the session propagates as an uncaught exception and exits 1.
--
-- The session runs through the runtime's public lifecycle: the logging lifetime over @stderr@,
-- entered first and left last, and the supervision boundary both owners are created under. Between
-- ticks it waits five milliseconds of real time so the UI owner, which updates every two, has
-- something to do; that pacing changes when a commit happens and never what it contains.
module Main (main) where

import Control.Concurrent (threadDelay)
import qualified Data.Text.IO as Text
import Hetoimasia.Foundation.Log (defaultLogFilter)
import Hetoimasia.Runtime.Application (runScopedApplication)
import Hetoimasia.Runtime.Logging (withHandleLoggingLifetime)
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configPace, configSeed, configTicks)
  , defaultConfig
  , renderReport
  , runSession
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Command (Command (..), Parsed (Help, Run), helpText, parseArguments, problemLine)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hFlush, hSetEncoding, stderr, stdout, utf8)

main ∷ IO ()
main = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  arguments ← getArgs
  case parseArguments arguments of
    Left problem → do
      Text.hPutStrLn stderr (problemLine problem)
      hFlush stderr
      exitWith (ExitFailure 2)
    Right Help → Text.putStr helpText
    Right (Run command) → runCommand command

runCommand ∷ Command → IO ()
runCommand command = do
  let config =
        defaultConfig
          { configTicks = Just (commandTicks command)
          , configSeed = commandSeed command
          , configPace = \_ → threadDelay 5000
          }
  report ←
    runScopedApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-lua-domains"
      (pure ())
      (\() _ → pure ())
      (\() control → withDomains control config runSession)
  mapM_ Text.putStrLn (renderReport report)
  hFlush stdout
