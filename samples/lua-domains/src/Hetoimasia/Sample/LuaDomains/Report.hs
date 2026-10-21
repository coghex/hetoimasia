-- | The headless session's one bounded report on stdout (#498 requirement 13, extended by #499 requirement 13):
-- the ticks committed, the session's final status with its evidence, the intentions by answer and by
-- disposition, the UI's controls and what it did, and the cleanup evidence of how it ended.
--
-- The report is a fixed number of lines, each a fixed label with numbers and a few bounded, escaped
-- texts (a message is cut to 120 characters), so its size does not depend on the session. It is the only
-- thing the executable writes to stdout.
module Hetoimasia.Sample.LuaDomains.Report
  ( renderReport
  , exitStatusOf
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains.Command (escapedText)
import Hetoimasia.Sample.LuaDomains.Domains
  ( Evidence (..)
  , InstanceEvidence (..)
  , OwnerEvidence (..)
  , SessionReport (..)
  )
import Hetoimasia.Sample.LuaDomains.Shared (UiNotes (..))
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure (..), SessionStatus (..), statusWord)
import Hetoimasia.Sample.LuaDomains.Tally (ControlCounts (..), Counts (..), Workspaces (..), countFull)
import Hetoimasia.Scripting.Lua.Instance (LeaseOutcome (..), Termination (..))
import Hetoimasia.Scripting.Lua.Runtime (ExitRecord (..))
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | The status the executable exits with: 0 when the session ended without a failure (a stop is not one), 1 when the
-- gameplay session failed or a UI failure was recorded.
exitStatusOf ∷ SessionReport → ExitCode
exitStatusOf report
  | failed || isJust (reportUiFailure report) = ExitFailure 1
  | otherwise = ExitSuccess
  where
    failed = case reportStatus report of
      Failed _ → True
      _ → False

-- | The report's lines.
renderReport ∷ SessionReport → [Text]
renderReport report =
  [ "hetoimasia-lua-domains: session " <> number (reportSession report) <> ", seed " <> number (reportSeed report) <> ", scenario " <> scenarioOf report
  , "ticks committed: " <> number (reportTicks report)
  , "status: " <> statusLine (reportStatus report)
  , "intentions answered: accepted " <> number (countAccepted counts) <> ", full " <> number (countFull counts) <> " (queue " <> number (countFullQueue counts) <> ", places " <> number (countFullPlaces counts) <> "), closed " <> number (countClosed counts) <> ", refused " <> number (countRefused counts) <> ", malformed " <> number (countMalformed counts)
  , "intentions settled: applied " <> number (countApplied counts) <> ", stale " <> number (countStale counts) <> ", invalidated " <> number (countInvalidated counts) <> ", discarded " <> number (countDiscarded counts)
  , "controls: offered " <> number (controlOffered controls) <> ", accepted " <> number (controlAccepted controls) <> ", refused " <> number (sum (Map.elems (controlRefused controls))) <> ", applied " <> number (controlApplied controls) <> ", already " <> number (controlAlready controls) <> ", no longer applicable " <> number (controlNoLonger controls) <> ", abandoned " <> number (controlAbandoned controls)
  , "ui: updates " <> number (reportUiUpdates report) <> ", busy " <> number (notesBusy notes) <> ", retried " <> number (notesRetried notes) <> ", saw " <> (if null (notesSaw notes) then "nothing" else Text.intercalate "," (notesSaw notes)) <> maybe ", no failure" (\failure → ", failure " <> failureLine failure) (reportUiFailure report)
  , "cleanup: ui " <> ownerLine (evidenceUi evidence) <> "; gameplay " <> ownerLine (evidenceGameplay evidence)
  , "cleanup: " <> Text.intercalate "; " (map instanceLine (evidenceInstances (evidenceGameplay evidence) <> evidenceInstances (evidenceUi evidence)))
  , "cleanup: workspaces acquired " <> number (workspacesAcquired workspaces) <> ", released " <> number (workspacesReleased workspaces) <> ", release failed " <> number (workspacesReleaseFailed workspaces) <> "; publication " <> (if evidencePublicationClosed evidence then "closed" else "open") <> "; pending " <> number (evidencePending evidence) <> "; failures told of " <> number (evidenceFailures evidence) <> ", after publication " <> number (length (evidenceAfter evidence))
  ]
  where
    counts = reportCounts report
    controls = reportControls report
    notes = reportUiNotes report
    evidence = reportEvidence report
    workspaces = evidenceWorkspaces evidence
    number ∷ Show a ⇒ a → Text
    number = Text.pack . show

-- | The scenario's name is the one the session was configured with; the report keeps it with the run.
scenarioOf ∷ SessionReport → Text
scenarioOf = reportScenario

statusLine ∷ SessionStatus → Text
statusLine status = case status of
  Failed evidence → "failed at tick " <> Text.pack (show (failTick (evidencePrimary evidence))) <> ": " <> failureLine (evidencePrimary evidence) <> ", later failures " <> Text.pack (show (evidenceLater evidence))
  other → statusWord other

-- | One failure on one line: who, where, what kind, and the message cut and escaped.
failureLine ∷ SessionFailure → Text
failureLine failure =
  escapedText 60 (failWho failure) <> " " <> failPhase failure <> " " <> failStage failure <> ", " <> failKind failure <> ": " <> escapedText 120 (failMessage failure)

ownerLine ∷ OwnerEvidence → Text
ownerLine owner =
  (if evidenceEnded owner then "ended" else "not ended")
    <> " (status "
    <> evidenceStatus owner
    <> maybe "" (\record → ", exit " <> Text.pack (show (exitKind record)) <> ", not started " <> Text.pack (show (exitNotStarted record)) <> ", in flight " <> Text.pack (show (exitStarted record))) (evidenceExit owner)
    <> ")"

instanceLine ∷ InstanceEvidence → Text
instanceLine instanceEvidence' =
  escapedText 40 (evidenceInstance instanceEvidence')
    <> " "
    <> evidenceOutcome instanceEvidence'
    <> " [shutdown "
    <> Text.pack (show (terminationShutdown (evidenceTermination instanceEvidence')))
    <> ", leases drained "
    <> Text.pack (show (leasesDrained (evidenceLeases instanceEvidence')))
    <> " failed "
    <> Text.pack (show (leasesFailed (evidenceLeases instanceEvidence')))
    <> "]"
