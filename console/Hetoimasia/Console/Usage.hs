-- | How the console reports a usage error: one writer, and one rule for the text it carries.
--
-- Every usage error of every path — the @lua@ subcommand's refusals, a refusal the runner returns, and
-- the top-level unknown argument — writes the usage line and a one-line reason to stderr, nothing to
-- stdout, and exits with 'usageExitCode'. The reason is built from what the user typed, so it is
-- escaped before it is written: every character that is not printable ASCII becomes a @\\xNN@ (or
-- @\\x{NNNN}@) escape, and each value is cut to a bound with a visible marker. A newline, a carriage return or
-- any other control in an argument or a path therefore cannot add a line, and a locale that cannot
-- encode the text cannot turn a usage error into a failure to report it.
module Hetoimasia.Console.Usage
  ( diagnosticText
  , oneLine
  , usageFailure
  , valueLimit
  ) where

import Data.Char (isAscii, isPrint, ord)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Hetoimasia.Console.Exit (usageExitCode)
import Numeric (showHex)
import System.Exit (exitWith)
import System.IO (hFlush, stderr)

-- | The most characters one value of the user's is shown with.
valueLimit ∷ Int
valueLimit = 200

-- | A value the user typed, as a part of a diagnostic: escaped by 'oneLine' and cut to 'valueLimit'
-- characters with a visible marker.
diagnosticText ∷ String → Text
diagnosticText value = cut (oneLine (Text.pack value))
  where
    cut text
      | Text.length text <= valueLimit = text
      | otherwise = Text.take (valueLimit - 3) text <> "..."

-- | Text with every character that is not printable ASCII replaced by an escape, so it is one line of
-- plain ASCII.
oneLine ∷ Text → Text
oneLine = Text.concatMap escape
  where
    escape character
      | isAscii character && isPrint character = Text.singleton character
      | ord character < 0x100 = Text.pack ("\\x" <> pad (showHex (ord character) ""))
      | otherwise = Text.pack ("\\x{" <> showHex (ord character) "}")
    pad digits = replicate (2 - length digits) '0' <> digits

-- | Write the usage line and a one-line reason, each on a line of its own, to stderr and nothing to
-- stdout, and leave with the usage status. The first argument is the reason's prefix.
usageFailure ∷ Text → Text → Text → IO a
usageFailure prefix usageLine reason = do
  Text.hPutStrLn stderr usageLine
  Text.hPutStrLn stderr (prefix <> oneLine reason)
  hFlush stderr
  exitWith usageExitCode
