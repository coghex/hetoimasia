-- | The @lua@ subcommand: its command line, its streams, its signals and its exit status, wired to the
-- script runner of "Hetoimasia.Scripting.Lua.Runner".
--
-- = The order of things
--
-- 1. The arguments are validated as a pure function ("Hetoimasia.Console.Lua.Options"). A refusal exits
--    2 before any file is read, any VM is started or any signal handler is installed.
-- 2. SIGINT and SIGTERM handlers, both calling the one coordinator ("Hetoimasia.Console.Lua.Signals"),
--    are installed, on this path only.
-- 3. The application runs through the public runtime lifecycle: the logging lifetime over @stderr@, the
--    supervision boundary, and the runner inside it, with the production clock and timer. The logging
--    lifetime is entered first and left last, so it outlives the supervision drain and makes the one
--    final flush after it.
-- 4. The runner's answer is mapped to the exit status ("Hetoimasia.Console.Lua.Status"). A failure of
--    the host and a cancellation propagate out of the path and keep 'exitOnFailure''s statuses.
--
-- = The streams
--
-- The runner's output sink is @stdout@ and its error sink is @stderr@, each flushed after every
-- write so a reader on a pipe sees each line at once. @print@ and the tables go to stdout; @warn@,
-- the failure and load reports and the usage text go to stderr, as the runner's contract and the owner's
-- decision on #492 have it. Both handles are UTF-8: the runner hands a sink text, and a locale that
-- cannot encode it must not turn a script's output into a host failure.
module Hetoimasia.Console.Lua
  ( runLua
  ) where

import Control.Concurrent.STM (STM)
import Control.Monad (void)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Hetoimasia.Console.Exit (cancellationExitCode)
import Hetoimasia.Console.Lua.Options
  ( LuaCommand (..)
  , LuaParse (LuaHelp, LuaRun)
  , ScriptSpec (..)
  , luaHelp
  , luaUsage
  , parseLua
  , problemReason
  )
import Hetoimasia.Console.Lua.Signals (deliver, newCoordinator, stopRequested)
import Hetoimasia.Console.Lua.Status (outcomeStatus, refusalLines)
import Hetoimasia.Console.Usage (usageFailure)
import Hetoimasia.Foundation.Log (LogFilter, Logger)
import Hetoimasia.Runtime.Application (runScopedApplication)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, withHandleLoggingLifetime)
import Hetoimasia.Scripting.Lua.Runner
  ( RunOutcome (Ran, Refused)
  , RunnerConfig (runnerLimit, runnerStop, runnerTick, runnerTickLimit)
  , Script (Script)
  , everyTicks
  , runScripts
  , runnerConfig
  )
import Hetoimasia.Scripting.Lua.Runtime (newLuaRuntime)
import System.Exit (ExitCode (ExitSuccess), exitWith)
import System.IO (hFlush, hSetEncoding, stderr, stdout, utf8)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

-- | Run the subcommand on the arguments after @lua@. Returns for status 0 and otherwise leaves with
-- the mapped status, which 'Hetoimasia.Console.Exit.exitOnFailure' passes through.
runLua ∷ LogFilter → [String] → IO ()
runLua configuration arguments = case parseLua arguments of
  Left problem → refuse (problemReason problem)
  Right LuaHelp → Text.putStr luaHelp
  Right (LuaRun command) → runCommand configuration command

-- | The usage line and the one-line reason, on stderr, and exit 2.
refuse ∷ Text → IO a
refuse = usageFailure "hetoimasia lua: " luaUsage

runCommand ∷ LogFilter → LuaCommand → IO ()
runCommand configuration command = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  -- Immediate and unceremonious: no handler, finalizer or flush runs, and the status is the signal's.
  coordinator ← newCoordinator (exitImmediately cancellationExitCode)
  let handler = Catch (void (deliver coordinator))
  _ ← installHandler sigINT handler Nothing
  _ ← installHandler sigTERM handler Nothing
  -- The runtime lifecycle hands its action no logger, so the lifetime's is kept as it is entered.
  loggerRef ← newIORef Nothing
  let enter ∷ ∀ r. (LoggingLifetime → IO r) → IO r
      enter continue = withHandleLoggingLifetime configuration stderr $ \lifetime → do
        writeIORef loggerRef (Just (lifetimeLogger lifetime))
        continue lifetime
  outcome ← runScopedApplication enter "hetoimasia" (pure ()) (\() _ → pure ()) $ \() control → do
    logger ← readIORef loggerRef >>= maybe (fail "the logging lifetime was not entered") pure
    runtime ← newLuaRuntime control
    runScripts runtime (runnerConfigFor logger command (stopRequested coordinator))
  case outcome of
    Refused refusal → refuse (Text.intercalate "; " (NonEmpty.toList (refusalLines refusal)))
    Ran _ → case outcomeStatus outcome of
      ExitSuccess → pure ()
      status → exitWith status

-- | The runner's inputs for a command: the options map one to one, the sinks are the process's streams
-- and the clock and timer are the production ones the runner's constructor supplies.
runnerConfigFor ∷ Logger → LuaCommand → STM Bool → RunnerConfig
runnerConfigFor logger command stop =
  (runnerConfig (luaVm command) scripts logger (writeLine stdout) (writeLine stderr))
    { runnerLimit = luaFor command
    , runnerTick = luaTick command
    , runnerTickLimit = luaTicks command
    , runnerStop = stop
    }
  where
    scripts =
      [ maybe id everyTicks (specEveryTicks spec) (Script (specPath spec) (specName spec) (specEvery spec))
      | spec ← NonEmpty.toList (luaScripts command)
      ]
    -- One line, flushed at once, so a reader on a pipe sees it as it is written.
    writeLine handle line = Text.hPutStrLn handle line >> hFlush handle
