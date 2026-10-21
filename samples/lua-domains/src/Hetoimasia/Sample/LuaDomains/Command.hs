-- | The executable's command line, as a pure function (requirement 13).
--
-- @hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME]@ runs a session; @--help@, alone, prints the
-- usage and exits 0. Anything else — an unknown argument, a repeated one, a missing or malformed value —
-- is refused with one reason, which the executable writes as a single bounded line on stderr
-- before it exits 2.
--
-- The reason names the problem and never echoes more than a bounded, escaped copy of what the
-- user typed, so a long or odd argument cannot make the line long or forge another.
module Hetoimasia.Sample.LuaDomains.Command
  ( Command (..)
  , Parsed (..)
  , parseArguments
  , Problem (..)
  , problemLine
  , usage
  , helpText
  , defaultTicks
  , maxTicks
  , escapedText
  ) where

import Data.Char (isAscii, isDigit, isPrint)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Normal), allScenarios, parseScenario, scenarioName)
import Numeric (showHex)

-- | What a session is asked to do.
data Command = Command
  { commandTicks ∷ !Word64
  , commandSeed ∷ !Word64
  , commandScenario ∷ !Scenario
  }
  deriving (Eq, Show)

-- | What the arguments mean.
data Parsed
  = Help
  | Run !Command
  deriving (Eq, Show)

-- | The ticks a session commits when none are asked for.
defaultTicks ∷ Word64
defaultTicks = 20

-- | The most ticks a session may be asked for.
maxTicks ∷ Word64
maxTicks = 100000

-- | Why the arguments were refused.
data Problem
  = -- | An argument that is no option.
    UnknownArgument !String
  | -- | An option that was given twice.
    RepeatedOption !String
  | -- | An option with no value after it.
    MissingValue !String
  | -- | An option's value that is not what it takes: the option and the value.
    MalformedValue !String !String
  | -- | @--help@ together with anything else.
    HelpAlone
  deriving (Eq, Show)

-- | Read the arguments.
parseArguments ∷ [String] → Either Problem Parsed
parseArguments = \case
  ["--help"] → Right Help
  arguments | "--help" `elem` arguments → Left HelpAlone
  arguments → Run <$> go Nothing Nothing Nothing arguments
  where
    go ticks seed scenario = \case
      [] → Right (Command (maybe defaultTicks id ticks) (maybe 1 id seed) (maybe Normal id scenario))
      "--ticks" : rest → option "--ticks" ticks rest $ \value more → do
        number ← readTicks value
        go (Just number) seed scenario more
      "--seed" : rest → option "--seed" seed rest $ \value more → do
        number ← readNumber "--seed" value
        go ticks (Just number) scenario more
      "--scenario" : rest → option "--scenario" scenario rest $ \value more → do
        named ← maybe (Left (MalformedValue "--scenario" value)) Right (parseScenario value)
        go ticks seed (Just named) more
      unknown : _ → Left (UnknownArgument unknown)
    option name held rest continue = case (held, rest) of
      (Just _, _) → Left (RepeatedOption name)
      (_, []) → Left (MissingValue name)
      (_, value : more) → continue value more
    readTicks value = do
      number ← readNumber "--ticks" value
      if number >= 1 && number <= maxTicks then Right number else Left (MalformedValue "--ticks" value)

-- | A value that is one to twenty digits and fits 64 bits.
readNumber ∷ String → String → Either Problem Word64
readNumber name value
  | not (null value) && length value <= 20 && all isDigit value && asInteger <= toInteger (maxBound ∷ Word64) = Right (fromInteger asInteger)
  | otherwise = Left (MalformedValue name value)
  where
    asInteger = read value ∷ Integer

-- | The usage, without a line break.
usage ∷ Text
usage = "usage: hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME] | --help"

-- | The one line a refusal is written as: the executable, the reason and the usage. Every
-- character of user text that is not printable ASCII is written as @\\xNN@ or @\\x{NNNN}@, and a
-- copy of user text is cut to a bound.
problemLine ∷ Problem → Text
problemLine problem = "hetoimasia-lua-domains: " <> reason <> "; " <> usage
  where
    reason = case problem of
      UnknownArgument argument → "unknown argument " <> quoted argument
      RepeatedOption name → "repeated option " <> name'
        where name' = Text.pack name
      MissingValue name → "missing value after " <> Text.pack name
      MalformedValue name value → "malformed value " <> quoted value <> " for " <> Text.pack name
      HelpAlone → "--help takes no other argument"

-- | A bounded, escaped copy of user text, in quotes.
quoted ∷ String → Text
quoted raw = "'" <> escapedText valueLimit (Text.pack raw) <> (if length raw > valueLimit then "...'" else "'")

-- | Text with everything that is not printable ASCII written as @\\xNN@ or @\\x{NNNN}@, cut to this many
-- characters before it is escaped.
escapedText ∷ Int → Text → Text
escapedText limit raw = Text.pack (concatMap escape (take limit (Text.unpack raw)))
  where
    escape character
      | isAscii character && isPrint character = [character]
      | fromEnum character < 256 = "\\x" <> pad 2 (showHex (fromEnum character) "")
      | otherwise = "\\x{" <> showHex (fromEnum character) "" <> "}"
    pad width digits = replicate (width - length digits) '0' <> digits

-- | The most characters of user text a refusal copies.
valueLimit ∷ Int
valueLimit = 64

-- | What @--help@ prints.
helpText ∷ Text
helpText =
  Text.unlines
    [ usage
    , ""
    , "Runs a UI Lua VM owner and a gameplay Lua VM owner side by side, headless, against a fixed"
    , "scripted fake input source, and prints one report on stdout."
    , ""
    , "  --ticks N   gameplay ticks to commit, 1 to " <> Text.pack (show maxTicks) <> " (default " <> Text.pack (show defaultTicks) <> ")"
    , "  --seed N    the gameplay session's random seed, 0 to 2^64-1 (default 1)"
    , "  --scenario  " <> Text.intercalate ", " (map scenarioName allScenarios) <> " (default normal): what the session also does"
    , "  --help      this text, on stdout, exit status 0"
    , ""
    , "Exit status: 0 after the report when the session ended without a failure (a stop is not a failure);"
    , "1 when the gameplay session failed or a UI failure was recorded; 2 for any usage error, with one line on stderr."
    ]
