-- | What a run of the @lua@ subcommand exits with, as pure functions of what the runner answered.
--
-- +------------------------------------------+--------+
-- | The runner answered                      | Status |
-- +==========================================+========+
-- | a usage refusal                          | 2      |
-- +------------------------------------------+--------+
-- | a report whose status is failure         | 1      |
-- +------------------------------------------+--------+
-- | a report whose status is interrupted     | 130    |
-- +------------------------------------------+--------+
-- | a report whose status is success         | 0      |
-- +------------------------------------------+--------+
--
-- The runner's status already ranks failure over interrupted over success, so 1 outranks 130, which
-- outranks 0 without a second ranking here. A failure of the host and a cancellation are not answers:
-- they propagate out of the run and keep 'Hetoimasia.Console.Exit.exitOnFailure''s statuses.
module Hetoimasia.Console.Lua.Status
  ( outcomeStatus
  , statusExit
  , refusalLines
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Hetoimasia.Console.Exit (cancellationExitCode, failureExitCode, usageExitCode)
import Hetoimasia.Scripting.Lua.Runner
  ( RunOutcome (Ran, Refused)
  , RunReport (reportStatus)
  , RunStatus (StatusFailure, StatusInterrupted, StatusSuccess)
  , UsageRefusal (UsageRefusal)
  , usageText
  )
import System.Exit (ExitCode (ExitSuccess))

-- | The exit status of a runner's answer.
outcomeStatus ∷ RunOutcome → ExitCode
outcomeStatus = \case
  Refused _ → usageExitCode
  Ran report → statusExit (reportStatus report)

-- | The exit status of a run's status value.
statusExit ∷ RunStatus → ExitCode
statusExit = \case
  StatusFailure → failureExitCode
  StatusInterrupted → cancellationExitCode
  StatusSuccess → ExitSuccess

-- | The reasons of a runner's refusal, one line each, in the order the runner gave them.
refusalLines ∷ UsageRefusal → NonEmpty Text
refusalLines (UsageRefusal violations) = fmap usageText violations
