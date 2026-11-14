-- | Everything this package's test executables write to standard output goes through one 'Output': the records the examples
-- print and the report the runner's formatter writes.
--
-- Two writers share the handle: the examples ('printLine', from any thread, the parallel group's eight included) and the
-- runner's formatter, whose events run on its own thread and write an item's text and its newline as separate writes. A
-- guarantee about a shared handle has to hold against both, so there is one lock and one record of whether the handle is at a
-- line start:
--
--   * 'printLine' writes its line, with its newline, as one write under the lock;
--   * 'guardFormatters' wraps every formatter the runner can select, so each formatter EVENT (a group header, an item's
--     result, the final report) runs under the same lock, to its end, and the event's formatter is known to end its events at a
--     line boundary ('boundaryFormatters', each event of which is shown in @docs/evidence/terrain/suite-budget/README.md@).
--     A formatter that is not known to (the @progress@ formatter writes a dot and no newline) leaves the handle mid-line
--     after an event, which the lock-held state records, and the next 'printLine' begins with a newline.
--
-- So a printed line starts at a line start and ends whole whatever the formatter, the buffering mode or the thread; on a
-- terminal it also clears the formatter's progress text on the line first. A line longer than the buffer (8 KiB) could be split
-- by the handle, and a line cut to fit would be a wrong record that looks right, so a line over 'maxLineChars' is never
-- printed: it fails the example that tries (each family line is a few hundred bytes).
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
