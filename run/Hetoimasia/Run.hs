-- | @hetoimasia run GAME_ROOT@: the generic launcher (LFE-22, P-71).
--
-- The executable knows how to assemble the engine's services, not what game or scene to run. Everything a game
-- is lives in the folder it is given: the manifest, the Lua and the content.
--
-- = The order of things
--
-- 1. The arguments are validated as a pure function ("Hetoimasia.Run.Options"). A refusal exits 2 before the
--    folder is looked at, any signal handler is installed, a worker is started or native graphics is touched.
--    @run --help@ alone prints the help and exits 0.
-- 2. SIGINT and SIGTERM handlers sharing one coordinator are installed for the scope of the run
--    ("Hetoimasia.Run.Signals"), before any boot work, and put back when it ends.
-- 3. The logging lifetime over stderr is entered; it is left last and makes the one final flush.
-- 4. The folder is opened once, scanned whole and checked ("Hetoimasia.Run.Boot"); a refusal is a boot failure
--    (1) and nothing authored has run. A first signal here abandons the work and exits 130 after it unwinds.
-- 5. The prepared folder is run with the production native graphics ("Hetoimasia.Run.Graphics") as one session
--    ("Hetoimasia.Run.Session") to the actual retirement of every role.
-- 6. The result is mapped to an exit status ("Hetoimasia.Run.Status") /after/ every scope has unwound, so a
--    status is never decided while a resource is still held.
--
-- = What this module owns
--
-- Process exit belongs to the root application: it is the only place in this command that leaves the process,
-- through 'exitWith' once everything has unwound, and through the signals' force action (an immediate exit with
-- status 130) on a second signal. No reusable provider exits the process.
--
-- = Diagnostics
--
-- Boot and host failures are logged once at error through the logger on stderr, with a single bounded and escaped
-- reason; the session reports its own failures (the first as primary, a bounded number of secondaries) the same
-- way. Authored @print@ is plain stdout and @warn@ the attributed stderr line. Nothing here retries a failed
-- report or replaces the original failure with a later one.
module Hetoimasia.Run
  ( -- * The command
    runRun
  , runUsage
  , runHelpEntry

    -- * Composition, for the suite
  , Setup (..)
  , production
  , runGame
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (SomeAsyncException, displayException, fromException, throwIO, try)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Hetoimasia.Console.Lua.Signals (Coordinator, stopRequested)
import Hetoimasia.Console.Usage (usageFailure)
import Hetoimasia.Foundation.Log (Component, LogFilter, logError, unsafeComponent)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Session (SessionOutcome)
import Hetoimasia.Run.Boot (BootEnd (..), BootHooks, Prepared, noBootHooks, withPreparedWith)
import Hetoimasia.Run.Graphics (runNative)
import Hetoimasia.Run.Options (RunParse (..), parseRun, problemReason, runHelp, runUsage)
import Hetoimasia.Run.Output (reportText, utf8Streams)
import Hetoimasia.Run.Session (productionEnvironment)
import Hetoimasia.Run.Signals (forceExit, withRunSignals)
import Hetoimasia.Run.Status (RunResult (..), bootFailed, exitStatus)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger, withHandleLoggingLifetime)
import System.Exit (ExitCode (ExitSuccess), exitWith)
import System.IO (stderr)

-- | What the command is composed with: the signals' force action and how a prepared folder is run. The
-- production values are 'production'; the suite supplies a force action it can count and a launch that
-- acquires no native session.
data Setup = Setup
  { setupForce ∷ IO ()
  , setupReady ∷ Coordinator → IO ()
  -- ^ Told the signal coordinator as soon as it exists, before any boot work: the suite delivers a signal
  -- through the very 'deliver' the installed handlers call.
  , setupBoot ∷ BootHooks
  , setupLaunch ∷ LoggingLifetime → STM Bool → Prepared → IO SessionOutcome
  }

-- | The command as it ships: a second signal leaves the process at once with 130, and the folder is run with the
-- production native graphics. No option, variable or fallback selects anything else.
production ∷ Setup
production = Setup forceExit (\_ → pure ()) noBootHooks (runNative productionEnvironment)

-- | The entry in the top-level help text (full build only).
runHelpEntry ∷ [Text]
runHelpEntry =
  [ "  run [--] GAME_ROOT   Run a game folder in a window (the full-product build)."
  , "                       See 'hetoimasia run --help'."
  ]

-- | Run the subcommand on the arguments after @run@. Returns for status 0 and otherwise leaves with the mapped
-- status, which 'Hetoimasia.Console.Exit.exitOnFailure' passes through.
runRun ∷ LogFilter → [String] → IO ()
runRun configuration arguments = case parseRun arguments of
  Left problem → usageFailure "hetoimasia run: " runUsage (problemReason problem)
  Right RunHelp → Text.putStr runHelp
  Right (RunRoot path) → do
    status ← runGame production configuration path
    case status of
      ExitSuccess → pure ()
      failure → exitWith failure

component ∷ Component
component = unsafeComponent "run"

-- | Everything after a valid command line, answering the exit status rather than leaving the process.
runGame ∷ Setup → LogFilter → FilePath → IO ExitCode
runGame setup configuration path = do
  utf8Streams
  result ← withRunSignals (setupForce setup) $ \coordinator → do
    setupReady setup coordinator
    withHandleLoggingLifetime configuration stderr $ \lifetime → do
      let stop = stopRequested coordinator
          logger = lifetimeLogger lifetime
      attempt ← try (withPreparedWith (setupBoot setup) logger fixedM1Profile stop path (setupLaunch setup lifetime stop))
      outcome ← case attempt of
        Left failure
          | isCancellation failure → throwIO failure
          | otherwise → do
              let reason = reportText (Text.pack (displayException failure))
              logError logger component "run failed" [("reason", reason)]
              pure (RunResult Nothing Nothing [reason] False)
        Right (Left (BootRefused reason)) → do
          logError logger component "boot failed" [("reason", reason)]
          pure (bootFailed reason False)
        Right (Left BootStopped) → pure (RunResult Nothing Nothing [] True)
        Right (Right session) → pure (RunResult (Just session) Nothing [] False)
      stopped ← atomically stop
      pure outcome {resultSignalled = resultSignalled outcome || stopped}
  pure (exitStatus result)
  where
    isCancellation failure = case fromException failure of
      Just (_ ∷ SomeAsyncException) → True
      Nothing → False
