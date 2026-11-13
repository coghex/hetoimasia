-- | One printed line of a parallel example, whole and starting at a line start.
--
-- Eight examples and the runner's formatter write to the same handle. A line printed by 'printLine' is one 'hPutStr' of one
-- string (the line, its newline and, on a terminal, a leading carriage return and erase-to-end-of-line that clear the
-- formatter's progress text on the current line), so the handle commits it as one block whatever the buffering mode (a pipe
-- block-buffers, a terminal line-buffers; a string of at most the buffer size is never split), and a lock serializes the
-- callers. A line longer than the buffer (8 KiB) could be split, and a line cut to fit would be a wrong record that looks
-- right, so a line over 'maxLineChars' is never printed: it fails the example that tries (each family line is a few hundred bytes).
--
-- State: one lock for the process, owned by this module, held only for the duration of one write.
module Test.TerrainRuntime.Output (printLine, maxLineChars) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import System.IO (hFlush, hIsTerminalDevice, hPutStr, stdout)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (expectationFailure)

outputLock ∷ MVar ()
outputLock = unsafePerformIO (newMVar ())
{-# NOINLINE outputLock #-}

-- | The most characters one printed line may have.
maxLineChars ∷ Int
maxLineChars = 4096

-- | Print a line to standard output as one write; a line over 'maxLineChars' fails the calling example and prints nothing.
printLine ∷ String → IO ()
printLine s
  | length s > maxLineChars = expectationFailure ("a printed line of " <> show (length s) <> " characters is over the " <> show maxLineChars <> " that one write may carry: " <> take 80 s)
  | otherwise = withMVar outputLock $ \_ → do
      tty ← hIsTerminalDevice stdout
      hPutStr stdout ((if tty then "\r\ESC[K" else "") <> s <> "\n")
      hFlush stdout
