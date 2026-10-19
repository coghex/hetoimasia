-- | How the runner writes: the one text form of a TID, the bounded and safe form of everything a
-- script can influence, the TID/OWNER/NAME/STATUS table and the failure reports.
--
-- Everything here is pure. A line is never longer than its bound plus the fixed words around it,
-- holds no line break and no control character but a tab where a script's own tab is kept, and
-- is one call of a sink: a script's text, an error message and a traceback cannot make a second
-- line of a report, because every line of a report is one the runner wrote and the script's text
-- sits inside it with its control characters replaced.
module Hetoimasia.Scripting.Lua.Runner.Render
  ( -- * Safe text
    tame
  , tameLine
  , cut
  , quoted

    -- * Identity and status words
  , tidText
  , phaseWord
  , stageWord

    -- * Reports
  , failureReport
  , failureLines
  , loadFailureLines

    -- * The table
  , TableRow (..)
  , tableLines
  , startTitle
  , endTitle

    -- * Script output
  , outputLines
  ) where

import Data.ByteString (ByteString)
import Data.Char (isControl, ord)
import Data.List (transpose)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import Data.Unique (hashUnique)
import Numeric (showHex)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( HookStage (..)
  , InstanceError
  , InstanceFailure (..)
  , InstanceId (..)
  , InstancePhase (..)
  , renderError
  )
import Hetoimasia.Scripting.Lua.Runner.Types
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId (OwnerId))

-- Safe text ------------------------------------------------------------------------------------

-- | Replace each control character with its escape, @\\xNN@ (@\\x@ and the two digits of its code, or
-- the four of a code past 255), so text a script influences is visible, reversible and cannot move a
-- cursor, rewrite a line or end one. Tab is replaced too.
tame ∷ Text → Text
tame = tameWith True

-- | 'tame', keeping a tab: a script's own @print@ joins its arguments with tabs.
tameLine ∷ Text → Text
tameLine = tameWith False

tameWith ∷ Bool → Text → Text
tameWith escapeTab = Text.concatMap $ \character →
  if isControl character && (escapeTab || character /= '\t')
    then Text.pack ("\\x" <> pad (showHex (ord character) ""))
    else Text.singleton character
  where
    pad digits = replicate (max 0 (2 - length digits)) '0' <> digits

-- | At most this many characters: a longer text is cut and ends with the truncation marker, which
-- counts toward the bound.
cut ∷ Int → Text → Text
cut limit text
  | Text.length text <= limit = text
  | limit <= Text.length truncationMarker = Text.take limit truncationMarker
  | otherwise = Text.take (limit - Text.length truncationMarker) text <> truncationMarker

-- | A value in a line: tamed, with the quote and the backslash escaped, between quotes.
quoted ∷ Text → Text
quoted text = "\"" <> Text.concatMap escape (tame text) <> "\""
  where
    escape character
      | character == '"' = "\\\""
      | character == '\\' = "\\\\"
      | otherwise = Text.singleton character

-- Identity and status words ---------------------------------------------------------------------

-- | A TID as text: the runtime's number, the owner's and the instance's, separated by dots, the
-- three integers of the record a script reads from @lifecycle.self@ and @lifecycle.inspect@.
tidText ∷ InstanceId → Text
tidText (InstanceId owner@(OwnerId scope _) local) =
  Text.intercalate "." [Text.pack (show (hashUnique scope)), Text.pack (show (ownerNumber owner)), Text.pack (show local)]
  where
    ownerNumber (OwnerId _ number) = number

-- | The status word of a phase: the lifecycle snapshot's.
phaseWord ∷ InstancePhase → Text
phaseWord = \case
  Initializing → "initializing"
  Active → "active"
  Paused → "paused"
  Stopping → "stopping"
  Completed → "completed"
  Stopped → "stopped"
  Failed → "failed"

-- | The stage a failure happened in, as a word.
stageWord ∷ HookStage → Text
stageWord = \case
  StageInit → "init"
  StageRun → "run"
  StageUpdate → "update"
  StageEvent source → "event " <> tame source
  StageShutdown → "shutdown"
  StageRelease → "release"

-- Reports ---------------------------------------------------------------------------------------

-- | The bounded report of a failed instance: the library's failure, its module's path as it was
-- given, and the VM's name. The error is cut to 'errorLimit' characters, the traceback to
-- 'tracebackLimit', and the secondary failures to 'secondaryLimit'.
failureReport ∷ Text → Text → InstanceFailure → FailureReport
failureReport vm file failure =
  FailureReport
    { frTid = failureInstance failure
    , frVm = tame (cut columnLimit vm)
    , frName = maybe "" (tame . cut nameLimit) (failureName failure)
    , frFile = file
    , frPhase = failurePhase failure
    , frStage = stageWord (failureStage failure)
    , frError = tame (cut errorLimit (failureMessage failure))
    , frTraceback = tameLines tracebackLimit <$> failureTraceback failure
    , frSecondary = [SecondaryFailure (stageWord stage) (secondaryText problem) | (stage, problem) ← kept]
    , frOmitted = length (failureSecondary failure) - length kept
    }
  where
    kept = take secondaryLimit (failureSecondary failure)
    secondaryText ∷ InstanceError → Text
    secondaryText = tame . cut errorLimit . renderError

-- A traceback keeps its own line breaks, which are tamed into a list of lines only when written.
tameLines ∷ Int → Text → Text
tameLines limit text = Text.intercalate "\n" (map tame (Text.splitOn "\n" (cut limit text)))

-- | The lines of a failure report, the ones a sink is written one call at a time: a header, then the
-- error, the traceback, and what else failed, each indented under it.
failureLines ∷ FailureReport → [Text]
failureLines report =
  [ "failure: instance "
      <> tidText (frTid report)
      <> " name="
      <> quoted (frName report)
      <> " script="
      <> quoted (frFile report)
      <> " vm="
      <> quoted (frVm report)
      <> " phase="
      <> phaseWord (frPhase report)
      <> " stage="
      <> frStage report
  , "  error: " <> frError report
  ]
    <> tracebackLines (frTraceback report)
    <> concat
      [ ["  also failed: " <> secondaryStage secondary <> ": " <> secondaryError secondary]
      | secondary ← frSecondary report
      ]
    <> [ "  " <> Text.pack (show (frOmitted report)) <> " more failures were not kept"
       | frOmitted report > 0
       ]

-- | The lines of the report of a source that did not load: the file as it was given and the VM, the
-- error and the traceback. It carries no TID.
loadFailureLines ∷ LoadFailure → [Text]
loadFailureLines failure =
  [ "failure: source did not load script=" <> quoted (loadFile failure) <> " vm=" <> quoted (loadVm failure)
  , "  error: " <> loadError failure
  ]
    <> tracebackLines (loadTraceback failure)

tracebackLines ∷ Maybe Text → [Text]
tracebackLines traceback =
  concat
    [ "  traceback:" : map ("    " <>) (Text.splitOn "\n" text)
    | text ← maybeToList traceback
    ]

-- The table -------------------------------------------------------------------------------------

-- | One row of the table, every cell already text.
data TableRow = TableRow
  { rowTid ∷ !Text
  , rowOwner ∷ !Text
  , rowName ∷ !Text
  , rowStatus ∷ !Text
  }

-- | The line that introduces the table written when the run has started.
startTitle ∷ Text
startTitle = "instances at start"

-- | The line that introduces the table written when the run has ended.
endTitle ∷ Text
endTitle = "instances at end"

-- | The table as lines: a header, then a row for each instance, in the order given. The owner and
-- name cells are cut to 'columnLimit' characters with the truncation marker and have their control
-- characters replaced; every column but the last is padded to its widest cell, and a line has no
-- trailing space.
tableLines ∷ [TableRow] → [Text]
tableLines rows = map render cells
  where
    cells = ["TID", "OWNER", "NAME", "STATUS"] : [[rowTid row, limited (rowOwner row), limited (rowName row), rowStatus row] | row ← rows]
    limited = cut columnLimit . tame
    widths = map (maximum . map Text.length) (transpose cells)
    render line = Text.stripEnd (Text.intercalate "  " [pad width cell | (width, cell) ← zip widths line])
    pad width cell = cell <> Text.replicate (width - Text.length cell) " "

-- Script output ---------------------------------------------------------------------------------

-- | The lines one call of @print@ or @warn@ writes: the bytes the script passed, decoded as UTF-8
-- with every invalid sequence replaced (so any Lua string is accepted, an embedded NUL byte and
-- invalid UTF-8 included), split at its line breaks, with the control characters of each line
-- replaced but its tabs kept. The script cut the text to 'outputCallLimit' bytes before it
-- crossed, and the lines are written whole.
outputLines ∷ ByteString → [Text]
outputLines bytes = map tameLine (Text.splitOn "\n" (Text.decodeUtf8With Text.lenientDecode bytes))
