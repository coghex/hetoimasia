-- | The @lua@ subcommand's command line, parsed as a pure function of the argument list.
--
-- Nothing here reads a file, starts a VM or installs a handler: a refusal found here is found before
-- any of them, and every refusal is a value with its own constructor, so each has a direct example.
--
-- = The grammar
--
-- Every option takes its value as the next argument; a value that is absent, empty, or itself begins
-- with @--@ is a missing value. /VM options/ may appear anywhere and at most once each: @--vm NAME@
-- (default @main@), @--scheduler fifo@ (the default and only value), @--headless@ (accepted, the
-- default and only mode), @--tick SECONDS@, @--for SECONDS@ and @--ticks N@. /Script options/ bind to
-- the most recent @--script PATH@ and at most once each for it: @--name NAME@ (default the file's
-- stem), @--every SECONDS@ and @--every-ticks N@.
--
-- Seconds are positive decimal numbers of at most nine fractional digits, no sign and no exponent, so
-- they are whole nanoseconds that fit the clock; zero, finer, malformed and unrepresentable values are
-- refused and nothing is rounded. Counts are positive whole numbers that fit a 64-bit tick.
--
-- @lua --help@ alone asks for help. Anything else that is not described here is a usage error.
module Hetoimasia.Console.Lua.Options
  ( -- * The result
    LuaParse (..)
  , LuaCommand (..)
  , ScriptSpec (..)
  , parseLua
    -- * Refusals
  , UsageProblem (..)
  , problemReason
    -- * Numbers
  , parseSeconds
  , parseCount
    -- * Text
  , luaUsage
  , luaHelp
  ) where

import Data.Char (isDigit)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.Console.Usage (diagnosticText)
import System.FilePath (takeBaseName)

-- | What the arguments after @lua@ ask for.
data LuaParse
  = -- | Run these scripts.
    LuaRun !LuaCommand
  | -- | Print the subcommand's help.
    LuaHelp
  deriving (Eq, Show)

-- | A valid run, every default filled in.
data LuaCommand = LuaCommand
  { luaVm ∷ !Text
  , luaTick ∷ !(Maybe Duration)
    -- ^ The tick duration: with it the VM runs on logical ticks.
  , luaFor ∷ !(Maybe Duration)
    -- ^ The run limit as a duration.
  , luaTicks ∷ !(Maybe Integer)
    -- ^ The run limit in ticks.
  , luaScripts ∷ !(NonEmpty ScriptSpec)
  }
  deriving (Eq, Show)

-- | One @--script@ and the options bound to it.
data ScriptSpec = ScriptSpec
  { specPath ∷ !FilePath
  , specName ∷ !(Maybe Text)
    -- ^ The name as given, or the file's stem when that is not empty.
  , specEvery ∷ !(Maybe Duration)
  , specEveryTicks ∷ !(Maybe Integer)
  }
  deriving (Eq, Show)

-- | Why the arguments were refused. The first one found, reading left to right, and then the
-- checks of the whole line in the order the constructors are listed.
data UsageProblem
  = -- | An option the command does not have.
    UnknownOption !String
  | -- | An argument that is not an option and not the value of one.
    UnknownArgument !String
  | -- | An option whose value is absent, empty or an option.
    MissingValue !String
  | -- | A VM option given twice.
    RepeatedVmOption !String
  | -- | A script option before the first @--script@.
    ScriptOptionBeforeScript !String
  | -- | A script option given twice for one script.
    RepeatedScriptOption !String !FilePath
  | -- | A scheduler other than @fifo@.
    SchedulerNotFifo !String
  | -- | A number that is malformed, zero, finer than a nanosecond or unrepresentable: the option and
    -- the value.
    MalformedNumber !String !String
  | -- | No @--script@.
    NoScript
  | -- | @--ticks@ without @--tick@.
    TicksWithoutTick
  | -- | @--every-ticks@ without @--tick@, for this script.
    EveryTicksWithoutTick !FilePath
  | -- | @--every@ together with @--tick@, for this script.
    EveryWithTick !FilePath
  | -- | @--every@ together with @--every-ticks@, for this script.
    EveryWithEveryTicks !FilePath
  deriving (Eq, Show)

-- | The one-line reason a refusal writes after the usage line.
problemReason ∷ UsageProblem → Text
problemReason = \case
  UnknownOption option → "unknown option " <> quote option
  UnknownArgument argument → "unknown argument " <> quote argument
  MissingValue option → shown option <> " needs a value"
  RepeatedVmOption option → shown option <> " was given more than once"
  ScriptOptionBeforeScript option → shown option <> " must follow the --script it applies to"
  RepeatedScriptOption option path → shown option <> " was given more than once for " <> quote path
  SchedulerNotFifo given → "the scheduler " <> quote given <> " is not supported; the only one is fifo"
  MalformedNumber option value → shown option <> " has an invalid value " <> quote value
  NoScript → "no --script was given"
  TicksWithoutTick → "--ticks needs --tick, the logical clock"
  EveryTicksWithoutTick path → "--every-ticks for " <> quote path <> " needs --tick, the logical clock"
  EveryWithTick path → "--every for " <> quote path <> " is an elapsed interval and the VM runs on ticks; use --every-ticks"
  EveryWithEveryTicks path → "--every and --every-ticks were both given for " <> quote path
  where
    -- Whatever the user typed is escaped and bounded: it is one line of plain ASCII.
    shown = diagnosticText
    quote value = "'" <> diagnosticText value <> "'"

-- | The state of one parse.
data Parsed = Parsed
  { parsedVm ∷ !(Maybe Text)
  , parsedScheduler ∷ !Bool
  , parsedHeadless ∷ !Bool
  , parsedTick ∷ !(Maybe Duration)
  , parsedFor ∷ !(Maybe Duration)
  , parsedTicks ∷ !(Maybe Integer)
  , parsedScripts ∷ ![ScriptSpec]
    -- ^ Newest first.
  }

-- | Parse the arguments after @lua@.
parseLua ∷ [String] → Either UsageProblem LuaParse
parseLua ["--help"] = Right LuaHelp
parseLua arguments = LuaRun <$> (go (Parsed Nothing False False Nothing Nothing Nothing []) arguments >>= finish)
  where
    go parsed [] = Right parsed
    go parsed (argument : rest) = case argument of
      "--vm" → valued argument rest $ \value remaining → once argument (parsedVm parsed) >> go parsed {parsedVm = Just (Text.pack value)} remaining
      "--scheduler" → valued argument rest $ \value remaining → do
        flagOnce argument (parsedScheduler parsed)
        if value == "fifo" then go parsed {parsedScheduler = True} remaining else Left (SchedulerNotFifo value)
      "--headless" → flagOnce argument (parsedHeadless parsed) >> go parsed {parsedHeadless = True} rest
      "--tick" → valued argument rest $ \value remaining → do
        once argument (parsedTick parsed)
        duration ← seconds argument value
        go parsed {parsedTick = Just duration} remaining
      "--for" → valued argument rest $ \value remaining → do
        once argument (parsedFor parsed)
        duration ← seconds argument value
        go parsed {parsedFor = Just duration} remaining
      "--ticks" → valued argument rest $ \value remaining → do
        once argument (parsedTicks parsed)
        count ← counted argument value
        go parsed {parsedTicks = Just count} remaining
      "--script" → valued argument rest $ \value remaining →
        go parsed {parsedScripts = ScriptSpec value Nothing Nothing Nothing : parsedScripts parsed} remaining
      "--name" → scriptOption parsed argument rest specName $ \value spec → pure spec {specName = Just (Text.pack value)}
      "--every" → scriptOption parsed argument rest specEvery $ \value spec → (\d → spec {specEvery = Just d}) <$> seconds argument value
      "--every-ticks" → scriptOption parsed argument rest specEveryTicks $ \value spec → (\n → spec {specEveryTicks = Just n}) <$> counted argument value
      ('-' : '-' : _) → Left (UnknownOption argument)
      _ → Left (UnknownArgument argument)
    -- An option's value is the next argument, which must exist, be non-empty and not be an option.
    valued option rest continue = case rest of
      value : remaining | not (null value), not (isOption value) → continue value remaining
      _ → Left (MissingValue option)
    isOption value = take 2 value == "--"
    once option present = maybe (Right ()) (const (Left (RepeatedVmOption option))) present
    flagOnce option seen = if seen then Left (RepeatedVmOption option) else Right ()
    seconds option value = maybe (Left (MalformedNumber option value)) Right (parseSeconds (Text.pack value))
    counted option value = maybe (Left (MalformedNumber option value)) Right (parseCount (Text.pack value))
    scriptOption ∷ ∀ x. Parsed → String → [String] → (ScriptSpec → Maybe x) → (String → ScriptSpec → Either UsageProblem ScriptSpec) → Either UsageProblem Parsed
    scriptOption parsed option rest current apply = case parsedScripts parsed of
      [] → Left (ScriptOptionBeforeScript option)
      spec : older → valued option rest $ \value remaining → do
        case current spec of
          Nothing → Right ()
          Just _ → Left (RepeatedScriptOption option (specPath spec))
        changed ← apply value spec
        go parsed {parsedScripts = changed : older} remaining
    finish parsed = case NonEmpty.nonEmpty (map named (reverse (parsedScripts parsed))) of
      Nothing → Left NoScript
      Just scripts@(first :| rest) → do
        if parsedTicks parsed /= Nothing && parsedTick parsed == Nothing then Left TicksWithoutTick else Right ()
        mapM_ (check parsed) (first : rest)
        Right
          LuaCommand
            { luaVm = maybe "main" id (parsedVm parsed)
            , luaTick = parsedTick parsed
            , luaFor = parsedFor parsed
            , luaTicks = parsedTicks parsed
            , luaScripts = scripts
            }
    check parsed spec
      | specEvery spec /= Nothing && specEveryTicks spec /= Nothing = Left (EveryWithEveryTicks (specPath spec))
      | specEvery spec /= Nothing && parsedTick parsed /= Nothing = Left (EveryWithTick (specPath spec))
      | specEveryTicks spec /= Nothing && parsedTick parsed == Nothing = Left (EveryTicksWithoutTick (specPath spec))
      | otherwise = Right ()
    -- A script's default name is its file's stem, when that is not empty.
    named spec = case specName spec of
      Just _ → spec
      Nothing → spec {specName = stemOf (specPath spec)}
    stemOf path = let stem = takeBaseName path in if null stem then Nothing else Just (Text.pack stem)

-- | Seconds as whole nanoseconds: digits, then optionally a point and one to nine digits. Positive,
-- and a duration the clock can represent.
parseSeconds ∷ Text → Maybe Duration
parseSeconds text = case Text.splitOn "." text of
  [whole] | digits whole → toDuration (read (Text.unpack whole) * 1000000000)
  [whole, fraction]
    | digits whole
    , digits fraction
    , Text.length fraction <= 9 →
        toDuration (read (Text.unpack whole) * 1000000000 + read (Text.unpack (Text.justifyLeft 9 '0' fraction)))
  _ → Nothing
  where
    toDuration nanoseconds = either (const Nothing) Just (durationFromNanoseconds RequirePositive nanoseconds)

-- | A positive whole number that fits a 64-bit tick.
parseCount ∷ Text → Maybe Integer
parseCount text
  | digits text, count >= 1, count <= toInteger (maxBound ∷ Word64) = Just count
  | otherwise = Nothing
  where
    count = read (Text.unpack text) ∷ Integer

digits ∷ Text → Bool
digits text = not (Text.null text) && Text.all isDigit text

-- | The usage line of the subcommand.
luaUsage ∷ Text
luaUsage = "Usage: hetoimasia lua [--vm NAME] [--scheduler fifo] [--headless] [--tick SECONDS] [--for SECONDS | --ticks N] --script PATH [--name NAME] [--every SECONDS | --every-ticks N] [--script PATH ...]"

-- | The subcommand's help.
luaHelp ∷ Text
luaHelp =
  Text.unlines
    [ luaUsage
    , ""
    , "Run Lua files as the instances of one VM until they have all ended, a limit is"
    , "reached, or the run is interrupted. Files are loaded and their instances admitted"
    , "in the order of the --script options."
    , ""
    , "VM options, each at most once, anywhere on the line:"
    , "  --vm NAME           The VM's name in the tables and reports. Default: main."
    , "  --scheduler fifo    The scheduling policy. fifo is the default and the only one."
    , "  --headless          Accepted; headless is the default and the only mode."
    , "  --tick SECONDS      Run on logical ticks of this many seconds, granted at that"
    , "                      real-time rate, instead of on elapsed time."
    , "  --for SECONDS       Stop after this much time."
    , "  --ticks N           Stop after N ticks. Needs --tick."
    , ""
    , "Script options, each at most once, applying to the most recent --script:"
    , "  --name NAME         The instance's name. Default: the file's name without its"
    , "                      directory and extension."
    , "  --every SECONDS     Call the module's update this often, in elapsed time."
    , "                      Not with --tick."
    , "  --every-ticks N     Call the module's update every N ticks. Needs --tick."
    , ""
    , "SECONDS is a positive decimal number of at most nine fractional digits, such as"
    , "0.5 or 0.000000001: no sign, no exponent. N is a positive whole number."
    , ""
    , "A module defining run is a one-shot; one defining update is looped and needs an"
    , "interval; one defining neither only reacts to events."
    , ""
    , "Output: print and the TID/OWNER/NAME/STATUS tables go to stdout; warn, failure"
    , "reports and diagnostics go to stderr."
    , ""
    , "Exit status:"
    , "  0    every instance completed or was stopped, by a control or a limit"
    , "  1    an instance failed or a file did not load"
    , "  2    invalid usage"
    , "  130  SIGINT or SIGTERM ended the run, after the orderly stop"
    , "When several apply, 1 outranks 130, which outranks 0. A second SIGINT or SIGTERM"
    , "while the orderly stop is still running exits at once with 130, without waiting"
    , "for the shutdown hooks that have not run."
    ]
