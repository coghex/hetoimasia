-- | What @hetoimasia run@ writes itself, and how: the authored sinks and the bounded report text.
--
-- Authored @print@ is plain stdout and @warn@ is the attributed stderr line the session's facade formats
-- ("Hetoimasia.LuaEngine.Facade"); both reach a stream through a sink that writes one line and flushes it, so a
-- reader on a pipe sees it as it is written. Both handles are UTF-8, because the facade hands a sink text and a
-- locale that cannot encode it must not turn a script's output into a host failure. A sink that raises is the
-- facade's fatal output failure (it ends the session as a host failure), so this module catches nothing.
--
-- The engine's own diagnostics (boot refusals, failures, lifecycle) go to stderr through the logger,
-- independently of the UI. The report text a launcher adds itself ('reportText') is one line, escaped and cut
-- to 'reportLimit' characters with a visible marker: no exception text is ever added unbounded.
module Hetoimasia.Run.Output
  ( authoredSinks
  , utf8Streams
  , reportText
  , reportLimit
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Hetoimasia.Console.Usage (oneLine)
import Hetoimasia.LuaEngine.Facade (OutputSink (..))
import System.IO (Handle, hFlush, hSetEncoding, stderr, stdout, utf8)

-- | The process's stdout and stderr as the authored sinks: one line, flushed at once.
authoredSinks ∷ (OutputSink, OutputSink)
authoredSinks = (sinkOf stdout, sinkOf stderr)
  where
    sinkOf ∷ Handle → OutputSink
    sinkOf handle = OutputSink {sinkLine = \line → Text.hPutStrLn handle line >> hFlush handle, sinkFlush = hFlush handle}

-- | Make both standard output handles UTF-8, before anything is written to either.
utf8Streams ∷ IO ()
utf8Streams = hSetEncoding stdout utf8 >> hSetEncoding stderr utf8

-- | The most characters a launcher-written report line holds.
reportLimit ∷ Int
reportLimit = 2048

-- | A report line from text of any length and content: escaped to one line of printable ASCII and cut, with a
-- visible marker, to 'reportLimit' characters.
reportText ∷ Text → Text
reportText text
  | Text.length escaped <= reportLimit = escaped
  | otherwise = Text.take (reportLimit - 3) escaped <> "..."
  where
    escaped = oneLine text
