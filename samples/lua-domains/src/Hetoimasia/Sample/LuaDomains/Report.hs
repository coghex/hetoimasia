-- | The headless session's one bounded report on stdout (#498 requirement 13, extended by #499 requirement 13 and #500
-- requirement 7): the ticks committed, the session's final status with its evidence, the intentions by answer and by
-- disposition, the UI's controls and what it did, the cleanup evidence of how it ended, and the final digest.
--
-- The report is a fixed number of lines, each a fixed label with numbers and a few bounded, escaped
-- texts (a message is cut to 120 characters), so its size does not depend on the session: eleven lines, and one more for a
-- replay and one more for a recording. The executable writes it to stdout, and after it the digest trace if @--digests@
-- asks, which is the only other thing it writes there.
module Hetoimasia.Sample.LuaDomains.Report
  ( renderReport
  , exitStatusOf
  , RecordOutcome (..)
  , renderRecordLine
  , renderTrace
  , digestMismatch
  , finalExit
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains.Canonical (Digest, digestHex)
import Hetoimasia.Sample.LuaDomains.Command (escapedText, quotedPath)
import Hetoimasia.Sample.LuaDomains.Domains
  ( Evidence (..)
  , InstanceEvidence (..)
  , OwnerEvidence (..)
  , ReplayOutcome (..)
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
  , "intentions answered: accepted " <> number (countAccepted counts) <> ", full " <> number (countFull counts) <> " (queue " <> number (countFullQueue counts) <> ", places " <> number (countFullPlaces counts) <> "), closed " <> number (countClosed counts) <> ", refused " <> number (countRefused counts) <> ", malformed " <> number (countMalformed counts) <> ", declined " <> number (countDeclined counts)
  , "intentions settled: applied " <> number (countApplied counts) <> ", stale " <> number (countStale counts) <> ", invalidated " <> number (countInvalidated counts) <> ", discarded " <> number (countDiscarded counts)
  , "controls: offered " <> number (controlOffered controls) <> ", accepted " <> number (controlAccepted controls) <> ", refused " <> number (sum (Map.elems (controlRefused controls))) <> ", applied " <> number (controlApplied controls) <> ", already " <> number (controlAlready controls) <> ", no longer applicable " <> number (controlNoLonger controls) <> ", abandoned " <> number (controlAbandoned controls)
  , "ui: updates " <> number (reportUiUpdates report) <> ", busy " <> number (notesBusy notes) <> ", retried " <> number (notesRetried notes) <> ", saw " <> (if null (notesSaw notes) then "nothing" else Text.intercalate "," (notesSaw notes)) <> maybe ", no failure" (\failure → ", failure " <> failureLine failure) (reportUiFailure report)
  , "cleanup: ui " <> ownerLine (evidenceUi evidence) <> "; gameplay " <> ownerLine (evidenceGameplay evidence)
  , "cleanup: " <> Text.intercalate "; " (map instanceLine (evidenceInstances (evidenceGameplay evidence) <> evidenceInstances (evidenceUi evidence)))
  , "cleanup: workspaces acquired " <> number (workspacesAcquired workspaces) <> ", released " <> number (workspacesReleased workspaces) <> ", release failed " <> number (workspacesReleaseFailed workspaces) <> "; publication " <> (if evidencePublicationClosed evidence then "closed" else "open") <> "; pending " <> number (evidencePending evidence) <> "; failures told of " <> number (evidenceFailures evidence) <> ", after publication " <> number (length (evidenceAfter evidence))
  , "final digest: " <> digestHex (reportDigest report) <> " (trace " <> number (length (reportTrace report)) <> " entries)"
  ]
    <> maybe [] (\outcome → [replayLine outcome]) (reportReplay report)
  where
    replayLine outcome =
      "replay: fed " <> number (replayFed outcome) <> " of " <> number (replayRecords outcome) <> " records, " <> case incomplete outcome of
        Nothing → "complete"
        Just why → "incomplete (" <> why <> ")"
    -- Complete is a replay that released every record and ended without a failure: an execution failure, which keeps
    -- the failure's status, is never reported as a complete replay.
    incomplete outcome = case reportStatus report of
      Failed evidence' → Just ("session failed at tick " <> number (failTick (evidencePrimary evidence')))
      _
        | isJust (reportUiFailure report) → Just "the UI failed"
        | replayFed outcome /= replayRecords outcome → Just "the session ended before every record's tick began"
        | otherwise → Nothing
    counts = reportCounts report
    controls = reportControls report
    notes = reportUiNotes report
    evidence = reportEvidence report
    workspaces = evidenceWorkspaces evidence
    number ∷ Show a ⇒ a → Text
    number = Text.pack . show

-- | What became of the recording @--record@ asked for.
data RecordOutcome
  = -- | No recording was asked for.
    NotRecording
  | -- | The log was written, whole: how many records, to this path.
    Recorded !Int !FilePath
  | -- | The log was not written: the path and why. The report never claims a recording that did not happen.
    RecordFailed !FilePath !Text

-- | The report's line for a recording, if one was asked for.
renderRecordLine ∷ RecordOutcome → [Text]
renderRecordLine = \case
  NotRecording → []
  Recorded count path → ["record: wrote " <> Text.pack (show count) <> " records to " <> quotedPath path]
  RecordFailed path why → ["record: FAILED, nothing was recorded to " <> quotedPath path <> ": " <> why]

-- | The digest trace, one line per entry, tick zero first.
renderTrace ∷ SessionReport → [Text]
renderTrace report = [ "digest " <> Text.pack (show tick) <> " " <> digestHex digest | (tick, digest) ← zip [0 ∷ Int ..] (reportTrace report)]

-- | The final digest and the one that was expected, when they differ.
digestMismatch ∷ SessionReport → Maybe Digest → Maybe (Digest, Digest)
digestMismatch report expected = case expected of
  Just wanted | wanted /= reportDigest report → Just (wanted, reportDigest report)
  _ → Nothing

-- | The status the executable exits with, once the digest was compared and the recording made: the session's own status
-- ('exitStatusOf') is what it is whatever the digest says, so a matching expected digest never turns a failure into a
-- success; a session that ended without a failure exits 1 when its digest was not the expected one or when a recording that
-- was asked for was not made.
finalExit ∷ SessionReport → Maybe Digest → RecordOutcome → ExitCode
finalExit report expected recorded = case exitStatusOf report of
  ExitFailure code → ExitFailure code
  ExitSuccess
    | isJust (digestMismatch report expected) || recordFailed → ExitFailure 1
    | otherwise → ExitSuccess
  where
    recordFailed = case recorded of
      RecordFailed _ _ → True
      _ → False

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
