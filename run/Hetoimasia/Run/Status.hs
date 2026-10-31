-- | The exit status of @hetoimasia run@, as a pure function of what the run came to (D-42, P-71).
--
-- +----------------------------------------------------+--------+
-- | What the run came to                               | Status |
-- +====================================================+========+
-- | A Lua @quit@, a native user close, an orderly end  | 0      |
-- +----------------------------------------------------+--------+
-- | A root, manifest, content, entry or boot failure;  | 1      |
-- | a script, a required-request, a host, a provider,  |        |
-- | an output or a cleanup failure; a session whose    |        |
-- | roles did not all retire                           |        |
-- +----------------------------------------------------+--------+
-- | Invalid command syntax (decided before a run)      | 2      |
-- +----------------------------------------------------+--------+
-- | An orderly SIGINT or SIGTERM stop that failed      | 130    |
-- | nothing                                            |        |
-- +----------------------------------------------------+--------+
--
-- The ranking is the session's own and is applied once more here to what the launcher adds: a failure
-- outranks an interruption, which outranks a normal quit or end, whatever order they arrived in. An error
-- after a quit, a sink failure or a cleanup failure therefore overrides a normal or a signal stop. A second
-- signal does not reach this function at all: it leaves the process at once with 130 and runs nothing.
module Hetoimasia.Run.Status
  ( RunResult (..)
  , bootFailed
  , exitStatus
  , resultFailed
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.Console.Exit (cancellationExitCode, failureExitCode)
import Hetoimasia.LuaEngine.Session (SessionOutcome (..), Verdict (..))
import System.Exit (ExitCode (ExitSuccess))

-- | Everything the status is decided from.
data RunResult = RunResult
  { resultOutcome ∷ !(Maybe SessionOutcome)
  -- ^ The session's outcome, when a session ran to its end.
  , resultBootFailure ∷ !(Maybe Text)
  -- ^ A failure before the session: the root, the manifest, the scan, the entries or the engine's construction.
  , resultHostFailures ∷ ![Text]
  -- ^ Failures of what surrounds the session: a pool, the root or the output closing, the graphics owner's
  -- own failure. They are evidence kept beside the first and each makes the run fail.
  , resultSignalled ∷ !Bool
  -- ^ A first SIGINT or SIGTERM asked for an orderly stop.
  }
  deriving (Eq, Show)

-- | A result of a run that did not get as far as a session.
bootFailed ∷ Text → Bool → RunResult
bootFailed reason signalled = RunResult Nothing (Just reason) [] signalled

-- | Whether any failure, of the session or of what surrounds it, is recorded.
resultFailed ∷ RunResult → Bool
resultFailed result =
  isJust (resultBootFailure result)
    || not (null (resultHostFailures result))
    || maybe False sessionFailed (resultOutcome result)
  where
    sessionFailed outcome = outVerdict outcome == VerdictFailure || not (outRetired outcome)

-- | The status of a run: 1 for any failure, else 130 for an interruption, else 0.
exitStatus ∷ RunResult → ExitCode
exitStatus result
  | resultFailed result = failureExitCode
  | interrupted = cancellationExitCode
  | otherwise = ExitSuccess
  where
    interrupted =
      resultSignalled result
        || maybe False ((== VerdictInterrupted) . outVerdict) (resultOutcome result)
