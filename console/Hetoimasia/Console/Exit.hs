-- | The console executable's exit mapping.
--
-- The runtime never exits the host process: its runners return a result or
-- rethrow a failure preservingly, and a cancellation propagates as itself. This
-- module is where the executable turns what propagated out of a path into an
-- exit status. It lives in the root package's private library rather than in
-- @app/@ so the suite can drive the mapping directly as well as through the
-- built executable.
--
-- +---------------------------------------------+-------------------------------------------+
-- | What left the path                          | What the executable does                  |
-- +=============================================+===========================================+
-- | Nothing: the path returned                  | Returns, so the process exits 0           |
-- +---------------------------------------------+-------------------------------------------+
-- | An 'ExitCode', such as a usage or           | Rethrows it unchanged                     |
-- | configuration @die@                         |                                           |
-- +---------------------------------------------+-------------------------------------------+
-- | A cancellation: anything thrown as          | Exits with 'cancellationExitCode', writing|
-- | asynchronous, including one arriving while  | nothing                                   |
-- | the failure line below is written           |                                           |
-- +---------------------------------------------+-------------------------------------------+
-- | Any other failure                           | One best-effort line on stderr naming it, |
-- |                                             | then exits with 'failureExitCode'         |
-- +---------------------------------------------+-------------------------------------------+
--
-- The stderr line is application output, not a diagnostic: the runtime has
-- already made whatever terminal report its logging lifetime allowed, and the
-- sink that carried it may be the thing that failed, so a failure to write the
-- line is ignored.
module Hetoimasia.Console.Exit
  ( exitOnFailure
  , failureExitCode
  , cancellationExitCode
  ) where

import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , displayException
  , fromException
  , rethrowIO
  , tryWithContext
  )
import Data.Maybe (isJust)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

-- | The status of a path that propagated a failure.
failureExitCode ∷ ExitCode
failureExitCode = ExitFailure 1

-- | The status of a path that was cancelled: 128 plus @SIGINT@'s number, as a
-- shell reports an interrupted command.
cancellationExitCode ∷ ExitCode
cancellationExitCode = ExitFailure 130

-- | Run one executable path and map what propagates out of it, as the module
-- header's table describes. 'exitWith' throws, so a caller other than @main@
-- receives the mapped 'ExitCode' as an exception.
exitOnFailure ∷ IO () → IO ()
exitOnFailure path = do
  outcome ← tryWithContext path
  case outcome of
    Right () → pure ()
    Left propagated@(ExceptionWithContext _ failure)
      | isJust (fromException failure ∷ Maybe ExitCode) → rethrowIO propagated
      | isCancellation failure → exitWith cancellationExitCode
      | otherwise → do
          written ← tryWithContext (hPutStrLn stderr ("hetoimasia: " <> displayException failure))
          case written ∷ Either (ExceptionWithContext SomeException) () of
            Left (ExceptionWithContext _ raised) | isCancellation raised → exitWith cancellationExitCode
            _ → exitWith failureExitCode

isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)
