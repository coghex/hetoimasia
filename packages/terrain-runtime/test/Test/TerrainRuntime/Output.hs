-- | The lines this package's routine and full-depth suites print to standard output, and the runner's formatter's report.
--
-- Two kinds of writer share the handle, and they are guarded differently.
--
--   * Through one 'Output' (a lock and a record of whether the handle is at a line start): every example of the parallel
--     group, which runs beside the formatter and beside seven other examples, the suite's own sequential lines (the
--     @RUNNER@, @PHASE@, @FIXTURE@, @MEMORY@, @DISCOVERY@, @REMOVAL@ and @KEYS@ lines), and the runner's formatter.
--     'printLine' writes its line with its newline as one write under the lock, preceded by a newline when the formatter left
--     the line open. 'guardFormatters' wraps every formatter the runner can select, so each formatter EVENT (a group header, an
--     item's result, the final report) runs under the same lock, to its end (the format returns when the event has been
--     written), and afterwards the record says the handle is at a line start for the formatters of 'boundaryFormatters', whose
--     every event ends in a newline or writes nothing, and open for any other (the @progress@ formatter writes a dot and no
--     newline). So neither writer can run inside the other's write, whatever the thread or the buffering mode, and a printed
--     line starts at a line start; on a terminal it also clears the formatter's progress text on the line first.
--   * Directly, with no lock: the sequential examples of the storage modules (@Test.TerrainRuntime.Storage.*@, #663's work), whose tests this change does not edit beyond placing them in the tiers. They are whole by the framework's
--     order, not by a lock: a sequential item starts only after the reporting thread has written every earlier item's result
--     ('Test.Hspec.Core.Runner.JobQueue.runSequentially' waits on a barrier that 'Test.Hspec.Core.Runner.Eval.reportItem'
--     signals after the item's own start has been reported, and each event is synchronous: 'Test.Hspec.Core.Format.monadic'
--     returns when the formatter has written it), so the formatter is idle until the item ends, and the isolation guard
--     ("Test.TerrainRuntime.Isolation") keeps every parallel example from running beside it. The oracle
--     ("Test.TerrainRuntime.OutputSpec") shows the case: sequential examples nested in describes, after a parallel group,
--     writing with @putStrLn@, are whole at a line start under every formatter of 'boundaryFormatters'. The same cannot be said
--     of the @progress@ formatter, whose dots leave the line open; a direct write then follows the dots.
--
-- A line longer than the buffer (8 KiB) could be split by the handle, and a line cut to fit would be a wrong record that looks
-- right, so a line over 'maxLineChars' is never printed through 'printLine': it fails the example that tries (each family
-- line is a few hundred bytes).
--
-- State: the process's 'Output' (and any a test makes for itself) owns one lock and one flag, written only under the lock,
-- for the life of the process; nothing resets or disposes them.
module Test.TerrainRuntime.Output
  ( Output
  , newOutput
  , globalOutput
  , printLine
  , printLineOn
  , withOutputLocked
  , guardFormatters
  , boundaryFormatters
  , maxLineChars
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO (hFlush, hIsTerminalDevice, hPutStr, stdout)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (expectationFailure)
import Test.Hspec.Runner (Config (..))

-- | The lock that serializes every write to standard output, and whether the handle is known to be at a line start.
data Output = Output
  { outLock ∷ MVar ()
  , outAtLineStart ∷ IORef Bool
  }

newOutput ∷ IO Output
newOutput = Output <$> newMVar () <*> newIORef True

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

-- | Print a line as one write under the output's lock: at a line start (a newline first when the formatter left the handle
-- mid-line) and with its newline. A line over 'maxLineChars' fails the calling example and prints nothing.
printLineOn ∷ Output → String → IO ()
printLineOn out s
  | length s > maxLineChars = expectationFailure ("a printed line of " <> show (length s) <> " characters is over the " <> show maxLineChars <> " that one write may carry: " <> take 80 s)
  | otherwise = withMVar (outLock out) $ \_ → do
      tty ← hIsTerminalDevice stdout
      atStart ← readIORef (outAtLineStart out)
      hPutStr stdout ((if atStart then "" else "\n") <> (if tty then "\r\ESC[K" else "") <> s <> "\n")
      hFlush stdout
      writeIORef (outAtLineStart out) True

-- | Run an action while no other writer of the output can write (a test that captures the handle holds it).
withOutputLocked ∷ Output → IO a → IO a
withOutputLocked out = withMVar (outLock out) . const

-- | The formatters whose every event ends at a line boundary, by the name @--format@ gives them. A formatter that is not
-- named here is treated as one that may leave a line open.
boundaryFormatters ∷ [String]
boundaryFormatters = ["checks", "specdoc", "failed-examples", "silent"]

-- | The configuration with every selectable formatter, and the default (@checks@), wrapped so that each of its events runs
-- under the output's lock and leaves the output's line-start record true or false by what the formatter is known to do. The
-- wrapped format is what the runner calls for every event, from the reporting thread and, for progress, from the example
-- threads; it returns when the event has been written, so the lock covers all of it.
guardFormatters ∷ Output → Config → Config
guardFormatters out cfg =
  cfg
    { configAvailableFormatters = wrapped
    , configFormat = case configFormat cfg of
        Just f → Just (guardFormat out False f)
        Nothing → lookup "checks" wrapped
    }
  where
    wrapped = [(name, guardFormat out (name `elem` boundaryFormatters) f) | (name, f) ← configAvailableFormatters cfg]

guardFormat ∷ Output → Bool → (c → IO (e → IO ())) → c → IO (e → IO ())
guardFormat out endsAtBoundary make config = do
  format ← make config
  pure $ \event → withMVar (outLock out) $ \_ → do
    writeIORef (outAtLineStart out) False
    format event
    writeIORef (outAtLineStart out) endsAtBoundary
