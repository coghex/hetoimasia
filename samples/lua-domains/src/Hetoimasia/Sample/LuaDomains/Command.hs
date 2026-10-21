-- | The executable's command line, as a pure function (requirement 13, extended by #500 requirement 7).
--
-- @hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME] [--record FILE] [--replay FILE] [--digests]
-- [--expect-digest HEX]@ runs a session; @--help@, alone, prints the usage and exits 0. Anything else — an unknown
-- argument, a repeated one, a missing or malformed value, a file that cannot be read or is no log, a log that cannot be
-- replayed, an output path that exists — is refused with one reason, which the executable writes as a single bounded line
-- on stderr before it exits 2.
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
  , quotedPath
  ) where

import Data.Char (isAscii, isDigit, isPrint)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains.Bounds (maxSessionTicks)
import Hetoimasia.Sample.LuaDomains.Canonical (Digest, parseDigest)
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Normal), allScenarios, parseScenario, scenarioName)
import Numeric (showHex)

-- | What a session is asked to do.
data Command = Command
  { commandTicks ∷ !Word64
  , commandSeed ∷ !Word64
  , commandScenario ∷ !Scenario
  , commandRecord ∷ !(Maybe FilePath)
    -- ^ Where to write the accepted-input log: a path that does not exist yet.
  , commandReplay ∷ !(Maybe FilePath)
    -- ^ The input log to replay: an existing, readable, valid file.
  , commandDigests ∷ !Bool
    -- ^ Print the digest trace.
  , commandExpect ∷ !(Maybe Digest)
    -- ^ The final digest the run is expected to end in.
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
maxTicks = maxSessionTicks

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
  | -- | The file @--replay@ names does not exist or cannot be read, or is larger than any log: the path and why.
    ReplayUnreadable !FilePath !Text
  | -- | The file @--replay@ names is no valid log: the path and the line's refusal.
    ReplayMalformed !FilePath !Text
  | -- | The log cannot be replayed in the session asked for: the path, the first reason and how many more there are.
    ReplayNotReplayable !FilePath !Text !Int
  | -- | The path @--record@ names cannot be written: the path and why.
    RecordRefused !FilePath !Text
  deriving (Eq, Show)

-- | The options read so far.
data Partial = Partial
  { partialTicks ∷ !(Maybe Word64)
  , partialSeed ∷ !(Maybe Word64)
  , partialScenario ∷ !(Maybe Scenario)
  , partialRecord ∷ !(Maybe FilePath)
  , partialReplay ∷ !(Maybe FilePath)
  , partialDigests ∷ !Bool
  , partialExpect ∷ !(Maybe Digest)
  }

-- | Read the arguments.
parseArguments ∷ [String] → Either Problem Parsed
parseArguments = \case
  ["--help"] → Right Help
  arguments | "--help" `elem` arguments → Left HelpAlone
  arguments → Run <$> go (Partial Nothing Nothing Nothing Nothing Nothing False Nothing) arguments
  where
    go partial = \case
      [] →
        Right
          Command
            { commandTicks = maybe defaultTicks id (partialTicks partial)
            , commandSeed = maybe 1 id (partialSeed partial)
            , commandScenario = maybe Normal id (partialScenario partial)
            , commandRecord = partialRecord partial
            , commandReplay = partialReplay partial
            , commandDigests = partialDigests partial
            , commandExpect = partialExpect partial
            }
      "--ticks" : rest → option "--ticks" (partialTicks partial) rest $ \value more → do
        number ← readTicks value
        go partial {partialTicks = Just number} more
      "--seed" : rest → option "--seed" (partialSeed partial) rest $ \value more → do
        number ← readNumber "--seed" value
        go partial {partialSeed = Just number} more
      "--scenario" : rest → option "--scenario" (partialScenario partial) rest $ \value more → do
        named ← maybe (Left (MalformedValue "--scenario" value)) Right (parseScenario value)
        go partial {partialScenario = Just named} more
      "--record" : rest → option "--record" (partialRecord partial) rest $ \value more → do
        path ← readPath "--record" value
        go partial {partialRecord = Just path} more
      "--replay" : rest → option "--replay" (partialReplay partial) rest $ \value more → do
        path ← readPath "--replay" value
        go partial {partialReplay = Just path} more
      "--expect-digest" : rest → option "--expect-digest" (partialExpect partial) rest $ \value more → do
        digest ← maybe (Left (MalformedValue "--expect-digest" value)) Right (parseDigest value)
        go partial {partialExpect = Just digest} more
      "--digests" : rest
        | partialDigests partial → Left (RepeatedOption "--digests")
        | otherwise → go partial {partialDigests = True} rest
      unknown : _ → Left (UnknownArgument unknown)
    option name held rest continue = case (held, rest) of
      (Just _, _) → Left (RepeatedOption name)
      (_, []) → Left (MissingValue name)
      (_, value : more) → continue value more
    readTicks value = do
      number ← readNumber "--ticks" value
      if number >= 1 && number <= maxTicks then Right number else Left (MalformedValue "--ticks" value)

-- | A path: not empty, not longer than 4096 characters and with no NUL, which no operating system takes.
readPath ∷ String → String → Either Problem FilePath
readPath name value
  | null value || length value > 4096 || '\NUL' `elem` value = Left (MalformedValue name value)
  | otherwise = Right value

-- | A value that is one to twenty digits and fits 64 bits.
readNumber ∷ String → String → Either Problem Word64
readNumber name value
  | not (null value) && length value <= 20 && all isDigit value && asInteger <= toInteger (maxBound ∷ Word64) = Right (fromInteger asInteger)
  | otherwise = Left (MalformedValue name value)
  where
    asInteger = read value ∷ Integer

-- | The usage, without a line break.
usage ∷ Text
usage = "usage: hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME] [--record FILE] [--replay FILE] [--digests] [--expect-digest HEX] | --help"

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
      ReplayUnreadable path why → "cannot read the replay file " <> quotedPath path <> ": " <> why
      ReplayMalformed path refusal → "the replay file " <> quotedPath path <> " is not a valid input log, " <> refusal
      ReplayNotReplayable path first more →
        "the replay file " <> quotedPath path <> " cannot be replayed in this session: " <> first <> (if more > 0 then " (and " <> Text.pack (show more) <> " more)" else "")
      RecordRefused path why → "cannot record to " <> quotedPath path <> ": " <> why

-- | A bounded, escaped copy of user text, in quotes.
quoted ∷ String → Text
quoted raw = "'" <> escapedText valueLimit (Text.pack raw) <> (if length raw > valueLimit then "...'" else "'")

-- | A path as a refusal quotes it: bounded and escaped, as any user text is.
quotedPath ∷ FilePath → Text
quotedPath = quoted

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
    , "  --record FILE   write the intentions and controls the session accepted, as an input log, to FILE, which must not exist"
    , "  --replay FILE   take the session's intentions and controls from the input log FILE and from nothing else:"
    , "                  the UI's offers are declined; FILE must exist, be readable and be valid, and be replayable here"
    , "  --digests       after the report, print the digest trace: one line per committed tick, and tick 0, at most "
        <> Text.pack (show (maxTicks + 1))
    , "  --expect-digest HEX   the final digest (64 hex digits) the run must end in"
    , "  --help      this text, on stdout, exit status 0"
    , ""
    , "Exit status: 0 after the report when the session ended without a failure (a stop is not a failure);"
    , "1 when the gameplay session failed or a UI failure was recorded, when the final digest differs from --expect-digest"
    , "(a match never changes a failure's status), or when --record could not be written (the report says so);"
    , "2 for any usage error, with one line on stderr and no report."
    ]
