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
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, mask, rethrowIO, try, tryWithContext)
import Control.Monad (unless, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Hetoimasia.Console.Lua.Signals (Coordinator, stopRequested)
import Hetoimasia.Console.Usage (usageFailure)
import Hetoimasia.Foundation.Log (LogFilter)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Session (SessionOutcome)
import Hetoimasia.Run.Boot (BootEnd (..), BootHooks, Prepared, noBootHooks, withPreparedWith)
import Hetoimasia.Run.Graphics (runNative)
import Hetoimasia.Run.Options (RunParse (..), parseRun, problemReason, runHelp, runUsage)
import Hetoimasia.Run.Output (reportText, utf8Streams)
import Hetoimasia.Run.Session (SessionLink, joinDiagnostics, newSessionLink, productionEnvironment)
import Hetoimasia.Run.Settle (combine, isAsynchronous)
import Hetoimasia.Run.Signals (forceExit, withRunSignals)
import Hetoimasia.Run.Status (RunResult (..), bootFailed, exitStatus)
import Hetoimasia.Runtime.Logging (LoggingLifetime, failedReportsInContext, flushFailuresInContext, lifetimeLogger, withHandleLoggingLifetime)
import Hetoimasia.Runtime.Reporting (raisedByDiagnostic)
import System.Exit (ExitCode (ExitSuccess), exitWith)
import System.IO (hFlush, stderr)

-- | What the command is composed with: the signals' force action and how a prepared folder is run. The
-- production values are 'production'; the suite supplies a force action it can count and a launch that
-- acquires no native session.
data Setup = Setup
  { setupForce ∷ IO ()
  , setupReady ∷ Coordinator → IO ()
  -- ^ Told the signal coordinator as soon as it exists, before any boot work: the suite delivers a signal
  -- through the very 'deliver' the installed handlers call.
  , setupBoot ∷ BootHooks
  , setupLifetime ∷ LogFilter → (∀ r. (LoggingLifetime → IO r) → IO r)
  -- ^ The logging lifetime the run is entered in: over stderr. A suite gives it a logger whose writes and flushes it
  -- counts and can break.
  , setupLink ∷ IO SessionLink
  -- ^ The link to whatever session is run: a fresh one. A suite gives it a diagnostics writer it can hold.
  , setupReport ∷ Text → IO ()
  -- ^ Where the one terminal line of a failure goes: stderr, best effort. A suite records it.
  , setupLaunch ∷ LoggingLifetime → STM Bool → SessionLink → Prepared → IO SessionOutcome
  -- ^ Run the prepared folder. The link is the command's: whatever session is bound to it is the one whose
  -- diagnostics writer the command joins before the logger is released.
  }

-- | The command as it ships: a second signal leaves the process at once with 130, and the folder is run with the
-- production native graphics. No option, variable or fallback selects anything else.
production ∷ Setup
production = Setup forceExit (\_ → pure ()) noBootHooks (\configuration → withHandleLoggingLifetime configuration stderr) newSessionLink report (runNative productionEnvironment)

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

-- | Everything after a valid command line, answering the exit status rather than leaving the process.
--
-- /Reporting./ Boot and host failures are reported by one best-effort line each on stderr, written /after/ every
-- scope has unwound, from outside the logging lifetime. They are not written through the logger: the lifetime and
-- the graphics owner's application have their own terminal reporting and their own record of a diagnostic path that
-- already failed, and a second unguarded write through that path would retry a failed report and could replace the
-- failure being reported with its own. The line is bounded and escaped, carries the cleanup failures retained
-- beside the primary one, and a failure to write it is ignored.
--
-- /Provenance./ A failure raised inside the logging lifetime is let go through it, as itself and with its context,
-- so the lifetime sees where it came from: a failure of a diagnostic is not followed by a final flush through the
-- path that just failed, and a failed report is recorded. It is caught only outside, and a failure of the lifetime
-- itself (its final flush) after the run came to an end is added to what was held, never substituted for it.
--
-- /The session's writer./ The session lets its diagnostics writer outlive the call, and it borrows the logger, so it
-- is joined, interruptibly and remembering a cancellation, before the lifetime releases the logger, after every
-- scope the session used has unwound, and on a failure as well as a success.
runGame ∷ Setup → LogFilter → FilePath → IO ExitCode
runGame setup configuration path = do
  utf8Streams
  link ← setupLink setup
  held ← newIORef Nothing
  outer ← tryWithContext $ withRunSignals (setupForce setup) $ \coordinator → do
    setupReady setup coordinator
    setupLifetime setup configuration $ \lifetime → do
      let stop = stopRequested coordinator
          logger = lifetimeLogger lifetime
      attempt ←
        withPreparedWith (setupBoot setup) logger fixedM1Profile stop path (setupLaunch setup lifetime stop link)
          `finalizing` joinDiagnostics link
      let (outcome, reports) = case attempt of
            Left (BootRefused reason) → (bootFailed reason False, ["boot failed: " <> reason])
            Left BootStopped → (RunResult Nothing Nothing [] True, [])
            Right session → (RunResult (Just session) Nothing [] False, [])
      stopped ← atomically stop
      let result = outcome {resultSignalled = resultSignalled outcome || stopped}
      writeIORef held (Just (result, reports))
      pure (result, reports)
  (result, reports) ← case outer of
    Right done → pure done
    Left failure
      | isAsynchronous failure → rethrowIO failure
      | otherwise → do
          let reason = failureReason failure
          prior ← readIORef held
          pure $ case prior of
            Just (result, reports) → (result {resultHostFailures = resultHostFailures result <> [reason]}, reports <> ["cleanup failed: " <> reason])
            Nothing → (RunResult Nothing Nothing [reason] False, ["run failed: " <> reason])
  -- A failure that came out of the diagnostic path itself says that path cannot be written: nothing more is written
  -- through it, and the stderr line is that same path. The status is the same.
  unless (diagnosticPathFailed outer) (mapM_ (setupReport setup) reports)
  pure (exitStatus result)

-- | Run an action and then a finalizer that answers a /remembered/ cancellation, whatever the action did, and keep
-- both: the action's failure (with its context) and a cancellation that arrived during the finalizer are combined
-- before either is raised, so neither is lost.
finalizing ∷ IO a → IO (Maybe (ExceptionWithContext SomeException)) → IO a
finalizing action finalizer = mask $ \restore → do
  outcome ← tryWithContext @SomeException (restore action)
  interruption ← finalizer
  case (interruption, outcome) of
    (Just interrupted, Left failure) → rethrowIO =<< combine interrupted [("the failure of what was being run", failure)]
    (Just interrupted, Right _) → rethrowIO interrupted
    (Nothing, _) → either rethrowIO pure outcome

-- | Whether the run ended with a failure of the diagnostic path: a marked startup diagnostic, a final flush or a
-- report that failed.
diagnosticPathFailed ∷ Either (ExceptionWithContext SomeException) a → Bool
diagnosticPathFailed = \case
  Right _ → False
  Left (ExceptionWithContext context _) →
    raisedByDiagnostic context || not (null (flushFailuresInContext context)) || not (null (failedReportsInContext context))

-- | A failure as one bounded line: what it says, then each cleanup failure retained beside it.
failureReason ∷ ExceptionWithContext SomeException → Text
failureReason (ExceptionWithContext context failure) =
  reportText . Text.intercalate "; " $
    Text.pack (displayException failure) : ["cleanup: " <> Text.pack (displayCleanupFailure retained) | retained ← cleanupFailuresInContext context]

-- | One line on stderr, best effort and once: a failure to write it changes nothing.
report ∷ Text → IO ()
report line = void (try (Text.hPutStrLn stderr ("hetoimasia run: " <> line) >> hFlush stderr) ∷ IO (Either SomeException ()))
