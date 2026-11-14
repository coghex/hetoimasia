-- | The lines this package's routine and full-depth suites print to standard output, and the runner's formatter's report.
--
-- Two kinds of writer share the handle, and they are guarded differently.
--
--   * Through one 'Output' (a lock and a record of whether the handle is at a line start): every example of the parallel
--     group, which runs beside the formatter and beside seven other examples, the suite's own sequential lines (the
--     @RUNNER@, @PHASE@, @FIXTURE@, @MEMORY@, @DISCOVERY@, @REMOVAL@ and @KEYS@ lines), and the runner's formatter.
--     'printLine' writes its line with its newline as one write under the lock. 'guardFormatters' wraps every formatter the
--     runner can select, so each formatter EVENT (a group header, an item's result, the final report) runs under the same lock,
--     to its end (the format returns when the event has been written). The line state is the model of what the events wrote:
--     'eventEffect' says, for each formatter, the configuration it was built with and each kind of event, whether the event writes
--     nothing (the state does not move), ends a line, leaves transient text and a held-back erase (when progress is reported, which
--     a file keeps as bytes), or leaves content open (the @progress@ formatter's dot). A line printed at a line start has nothing
--     before it; after transient text, on a terminal the erase and on any other handle a newline; after open content a newline.
--     The model is not trusted: "Test.TerrainRuntime.OutputSpec" drives every formatter through every kind of event, observes the
--     bytes each writes and compares them with the model, and prints a record at every position of the sequence. A formatter the
--     model does not name is taken to leave every event open, which costs a newline and never a damaged record. So neither writer
--     can run inside the other's write, whatever the thread or the buffering mode, and a printed line starts a line of the
--     bytes; on a terminal it also clears the formatter's progress text on the line first.
--   * Directly, with no lock: the sequential examples of the storage modules (@Test.TerrainRuntime.Storage.*@, #663's work), whose tests this change does not edit beyond placing them in the tiers. They are whole by the framework's
--     order, not by a lock: a sequential item starts only after the reporting thread has written every earlier item's result
--     ('Test.Hspec.Core.Runner.JobQueue.runSequentially' waits on a barrier that 'Test.Hspec.Core.Runner.Eval.reportItem'
--     signals after the item's own start has been reported, and each event is synchronous: 'Test.Hspec.Core.Format.monadic'
--     returns when the formatter has written it), so the formatter is idle until the item ends, and the isolation guard
--     ("Test.TerrainRuntime.Isolation") keeps every parallel example from running beside it. The oracle
--     ("Test.TerrainRuntime.OutputSpec") shows the case: sequential examples nested in describes, after a parallel group,
--     writing with @putStrLn@, are whole at a line start under every formatter but @progress@. The same cannot be said
--     of the @progress@ formatter, whose dots leave the line open (a direct write then follows the dots), nor, when progress is
--     reported, of the bytes of a file (a direct write follows the transient text and its erase, whole as a terminal shows it), nor
--     of any configuration outside 'modelDomain' (with html output, which wraps what a formatter writes in a span that closes after
--     the newline, a direct write follows a closing tag; likewise after an external diff command or a diff context the model does
--     not name): the line is left open there, and only what goes through 'printLine' begins at a line start.
--
-- A line longer than the buffer (8 KiB) could be split by the handle, and a line cut to fit would be a wrong record that looks
-- right, so a line over 'maxLineChars' is never printed through 'printLine': it fails the example that tries (each family
-- line is a few hundred bytes).
--
-- State: the process's 'Output' (and any a test makes for itself) owns one lock and one line state, written only under the lock,
-- for the life of the process; nothing disposes them, and a formatter's creation resets the line state to what the runner has
-- written by then (the hidden cursor).
module Test.TerrainRuntime.Output
  ( Output
  , newOutput
  , globalOutput
  , printLine
  , printLineOn
  , withOutputLocked
  , guardFormatters
  , Effect (..)
  , eventEffect
  , modelDomain
  , maxLineChars
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing)
import System.IO (hFlush, hIsTerminalDevice, hPutStr, stdout)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (expectationFailure)
import Test.Hspec.Core.Format (Event (..), Format, FormatConfig (..))
import Test.Hspec.Runner (Config (..))

-- | Where the handle is, as far as the last write told: at a line start; after transient text (a formatter that reports progress
-- writes the text of the item it is running and an erase of it that the handle holds back, which a terminal never shows and a file
-- keeps as the bytes of a line); or mid-line after content (the @progress@ formatter's dots).
data LineState = AtLineStart | AfterTransient | MidLine
  deriving stock (Eq, Show)

-- | The lock that serializes every write to standard output, and where the handle is.
data Output = Output
  { outLock ∷ MVar ()
  , outLineState ∷ IORef LineState
  }

newOutput ∷ IO Output
newOutput = Output <$> newMVar () <*> newIORef AtLineStart

-- | The process's output: the one the suite's examples and the runner's formatter use.
globalOutput ∷ Output
globalOutput = unsafePerformIO newOutput
{-# NOINLINE globalOutput #-}

-- | The most characters one printed line may have.
maxLineChars ∷ Int
maxLineChars = 4096

-- | Print a line to the process's output as one write; see 'printLineOn'.
printLine ∷ String → IO ()
printLine = printLineOn globalOutput

-- | Print a line as one write under the output's lock, at a line start of the bytes and with its newline: nothing before it when
-- the handle is at a line start; after transient text, on a terminal the erase (the transient text is never shown) and on any
-- other handle a newline (the bytes of the transient text and its erase are a line of the file); after content, a newline.
-- A line over 'maxLineChars' fails the calling example and prints nothing.
printLineOn ∷ Output → String → IO ()
printLineOn out s
  | length s > maxLineChars = expectationFailure ("a printed line of " <> show (length s) <> " characters is over the " <> show maxLineChars <> " that one write may carry: " <> take 80 s)
  | otherwise = withMVar (outLock out) $ \_ → do
      tty ← hIsTerminalDevice stdout
      state ← readIORef (outLineState out)
      let erase = if tty then "\r\ESC[K" else ""
          before = case state of
            AtLineStart → erase
            AfterTransient → if tty then erase else "\n"
            MidLine → "\n" <> erase
      hPutStr stdout (before <> s <> "\n")
      hFlush stdout
      writeIORef (outLineState out) AtLineStart

-- | Run an action while no other writer of the output can write (a test that captures the handle holds it).
withOutputLocked ∷ Output → IO a → IO a
withOutputLocked out = withMVar (outLock out) . const

-- | What an event of a formatter leaves on the line the handle is at.
data Effect
  = Silent -- ^ it writes nothing: the line is as it was
  | EndsLine -- ^ it ends with a newline: the next write starts a line
  | LeavesTransient -- ^ it ends with transient text and a held-back erase of it (progress reporting)
  | LeavesOpen -- ^ it ends with content and no newline (a dot of the @progress@ formatter)
  deriving stock (Eq, Show)

-- | The configurations the model answers for. What a formatter writes is a function of the whole 'FormatConfig' and of each
-- event's payload, so the model names its domain, and OUTSIDE IT EVERY EVENT LEAVES THE LINE OPEN (a newline before the next
-- printed line, never a damaged record). The pattern names all fifteen fields by position, so a field a later Hspec adds does
-- not compile unnoticed. For each field, one of three statuses (the oracle varies every field marked swept, with payloads for
-- every kind of result and failure, and compares the model with the bytes each event wrote):
--
--   1. @formatConfigUseColor@: swept, both values (colour sequences, reset before the newline).
--   2. @formatConfigReportProgress@: swept, both values (transient text; the runner's cursor pair).
--   3. @formatConfigOutputUnicode@: swept, both values (the symbol of a result, the same place).
--   4. @formatConfigUseDiff@: swept, both values (text of a failure report, inside the end of the run).
--   5. @formatConfigDiffContext@: pinned to the values swept, @Nothing@, @Just 0@ and @Just 3@ (the default); any other value is outside.
--   6. @formatConfigExternalDiff@: pinned to @Nothing@: an external command writes to standard output whatever it likes.
--   7. @formatConfigPrettyPrint@: read by no formatter ('Test.Hspec.Core.Formatters.V2' reads the function, not this flag); swept anyway.
--   8. @formatConfigPrettyPrintFunction@: a function, so not enumerable; its result is only text inside the failure report, written
--      by @writeChunks@ with a newline after every chunk (V2.hs, the failure formatter), inside the end of the run, whose last
--      write is the footer line; swept with functions whose results are empty and several lines long, and @Nothing@.
--   9. @formatConfigFormatException@: likewise a function; its result is written by @indent@ (V2.hs, the failure formatter), one
--      line at a time with a newline each; swept with an empty and a several-line result.
--  10. @formatConfigPrintTimes@: swept, both values (text before the newline of the same line).
--  11. @formatConfigHtmlOutput@: swept, and OUTSIDE the domain when set: every coloured write is wrapped in a span that closes
--      after the newline ('Test.Hspec.Core.Formatters.Internal.htmlSpan'), so an event ends with a closing tag and no newline;
--      hspec's own transient text is then off, too. Not modelled, so every event is open.
--  12. @formatConfigPrintCpuTime@: swept, both values (text of the footer line).
--  13. @formatConfigUsedSeed@: read only inside two lines written with a newline (V2.hs: the seed line of the failure report); swept with two values.
--  14. @formatConfigExpectedTotalCount@: read by no formatter of the five ('getExpectedTotalCount' is exported and unused); set to the real count in the sweep.
--  15. @formatConfigExpertMode@: swept, both values (it omits lines of the failure report).
modelDomain ∷ FormatConfig → Bool
modelDomain
  ( FormatConfig
      _useColor
      _reportProgress
      _outputUnicode
      _useDiff
      diffContext
      externalDiff
      _prettyPrint
      _prettyPrintFunction
      _formatException
      _printTimes
      htmlOutput
      _printCpuTime
      _usedSeed
      _expectedTotalCount
      _expertMode
    ) = not htmlOutput && isNothing externalDiff && diffContext `elem` [Nothing, Just 0, Just 3]

-- | The model: for a formatter by the name @--format@ gives it, the format configuration it was built with and an event, what the
-- event leaves on the line. Inside 'modelDomain' it is checked against the bytes each event of each formatter writes
-- ("Test.TerrainRuntime.OutputSpec" drives every formatter through every kind of event and compares). A formatter that is not
-- named here, and every configuration outside the domain, leaves every event 'LeavesOpen': where the model is not certain, the
-- line is taken to be open, which costs a newline and never a damaged record.
eventEffect ∷ String → FormatConfig → Event → Effect
eventEffect formatter config event
  | not (modelDomain config) = LeavesOpen
  | otherwise = case formatter of
      "checks" → case event of
        Started → EndsLine
        GroupStarted {} → EndsLine
        GroupDone {} → Silent
        Progress {} → transient
        ItemStarted {} → transient
        ItemDone {} → EndsLine
        Done {} → EndsLine
      "specdoc" → case event of
        Started → EndsLine
        GroupStarted {} → EndsLine
        GroupDone {} → Silent
        Progress {} → transient
        ItemStarted {} → Silent
        ItemDone {} → EndsLine
        Done {} → EndsLine
      "progress" → case event of
        ItemDone {} → LeavesOpen
        Done {} → EndsLine
        _ → Silent
      "failed-examples" → case event of
        Done {} → EndsLine
        _ → Silent
      "silent" → Silent
      _ → LeavesOpen
  where
    transient = if formatConfigReportProgress config then LeavesTransient else Silent

-- | The line state after an event of the given effect; an event that writes nothing leaves the state it found.
afterEffect ∷ Effect → LineState → LineState
afterEffect effect before = case effect of
  Silent → before
  EndsLine → AtLineStart
  LeavesTransient → AfterTransient
  LeavesOpen → MidLine

-- | The configuration with every selectable formatter, and the default (@checks@), wrapped so that each of its events runs
-- under the output's lock and leaves the output's line state by the model of what the formatter writes ('eventEffect'). The
-- wrapped format is what the runner calls for every event, from the reporting thread and, for progress, from the example
-- threads; it returns when the event has been written, so the lock covers all of it.
guardFormatters ∷ Output → Config → Config
guardFormatters out cfg =
  cfg
    { configAvailableFormatters = wrapped
    , configFormat = case configFormat cfg of
        Just f → Just (guardFormat out "" f)
        Nothing → lookup "checks" wrapped
    }
  where
    wrapped = [(name, guardFormat out name f) | (name, f) ← configAvailableFormatters cfg]

-- | One formatter, guarded. The runner hands it the configuration it built, which says whether progress is reported
-- ('formatConfigReportProgress': colour on and neither GitHub Actions nor Buildkite): then the runner has already hidden the
-- cursor (a control sequence, no newline) before the first event, so the line starts 'AfterTransient' and stays so until an
-- event that writes something moves it; and it shows the cursor again after the last ('Done') event, so the line is
-- 'AfterTransient' after the run whatever the formatter wrote. These two are the only bytes the runner writes to standard output
-- outside a formatter's events ('Test.Hspec.Core.Runner.withHiddenCursor').
guardFormat ∷ Output → String → (FormatConfig → IO Format) → FormatConfig → IO Format
guardFormat out name make config = do
  format ← make config
  let progress = formatConfigReportProgress config
      known = modelDomain config
  withMVar (outLock out) $ \_ → writeIORef (outLineState out) (if progress then AfterTransient else AtLineStart)
  pure $ \event → withMVar (outLock out) $ \_ → do
    before ← readIORef (outLineState out)
    writeIORef (outLineState out) MidLine
    format event
    writeIORef (outLineState out) (case event of
      Done {} | progress, known → AfterTransient
      _ → afterEffect (eventEffect name config event) before)
