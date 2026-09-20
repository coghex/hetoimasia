-- | Structured synchronous logging through an explicit, injectable sink.
--
-- A 'Logger' is an opaque value built by 'mkLoggerWith' (or the production
-- 'mkLogger'), carrying a pure 'LogFilter', a 'LogSink', injectable
-- 'MetadataProviders', and the immutable context added by 'withFields' and
-- 'withBreadcrumb'. There is no global or shared mutable logging state: a
-- subsystem or worker receives its own derived logger explicitly.
--
-- Emission is gated by the filter before the message or fields are forced and
-- before any metadata provider runs, so a suppressed entry costs no payload
-- evaluation, timestamp, or thread lookup. Sinks are synchronous and their
-- exceptions propagate to the caller.
--
-- 'formatEntry' renders one entry as exactly one line of text; 'newHandleSink'
-- writes those lines to a borrowed handle, serializing every write and flush
-- across the loggers sharing it. The handle stays the caller's: the sink never
-- closes it and never changes its buffering.
--
-- 'writeEntry' and 'flushSink' forward an already-prepared entry, and a flush,
-- to a sink an adapter has borrowed. They are the whole of what a caller
-- holding a 'LogSink' can do to it: neither exposes the sink's construction or
-- its internals, and both keep the sink's own synchronous write, flush, and
-- exception semantics. Rebuilding an entry through 'logEvent' instead would
-- replace its source attribution and re-apply a filter it has already passed.
--
-- 'parseLogLevel', 'parseComponentLevels', and 'parseDebugSelection' validate
-- the three configurable parts of a 'LogFilter' without performing IO and
-- without knowing where the text came from. 'resolveLogFilter' assembles them
-- over a caller-supplied lookup and a caller-supplied 'LogVariables', so the
-- variable names and the environment access both belong to the application.
--
-- See @docs/logging.md@ for the same contract in prose, including the record
-- layout, the quoting rules, and the ownership and failure obligations.
module Hetoimasia.Foundation.Log
  ( -- * Severity
    LogLevel (..)

    -- * Components
  , Component
  , mkComponent
  , unsafeComponent
  , componentText

    -- * Filter configuration
  , LogFilter (..)
  , DebugSelection (..)
  , defaultLogFilter

    -- * Startup configuration
  , parseLogLevel
  , parseComponentLevels
  , parseDebugSelection
  , LogVariables (..)
  , resolveLogFilter

    -- * Entries
  , LogEntry (..)
  , SourceLocation (..)

    -- * Record layout
  , FormatOptions (..)
  , defaultFormatOptions
  , formatEntry

    -- * Sinks
  , LogSink
  , newHandleSink
  , newHandleSinkWith
  , callbackSink
  , callbackSinkWith

    -- * Forwarding to a sink
  , writeEntry
  , flushSink

    -- * Metadata providers
  , MetadataProviders (..)
  , systemMetadata

    -- * Loggers
  , Logger
  , mkLoggerWith
  , mkLogger
  , handleLogger

    -- * Scoped context
  , withFields
  , withBreadcrumb

    -- * Flushing
  , flushLogger

    -- * Emission
  , logEvent
  , logDebug
  , logInfo
  , logWarning
  , logError
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (foldM, when)
import Data.Char (isAsciiLower, isControl, isDigit, isPrint, isSpace, ord)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (UTCTime (utctDayTime), diffTimeToPicoseconds, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Stack
  ( CallStack
  , HasCallStack
  , callStack
  , getCallStack
  , srcLocFile
  , srcLocStartLine
  , withFrozenCallStack
  )
import System.IO (Handle, hFlush)

-- | Severity, ordered from most to least detailed. The ordering is used for
-- threshold comparisons; 'Debug' is never selected by a threshold (see
-- 'LogFilter').
data LogLevel = Debug | Info | Warning | Error
  deriving (Eq, Ord, Show)

-- | A validated component name: one or more nonempty segments matching
-- @[a-z][a-z0-9_-]*@ joined by @.@, for example @gpu.vulkan@ or @game.world@.
--
-- Matching is exact everywhere — there is no hierarchy, registry, or central
-- enum — so @gpu@ and @gpu.vulkan@ are unrelated names. Build one with
-- 'mkComponent'; the constructor is private so every component in an entry or
-- a filter has been validated.
newtype Component = Component Text
  deriving (Eq, Ord, Show)

-- | Validate a component name, rejecting an invalid one with a descriptive
-- message rather than normalizing it. The standalone names @all@ and @none@
-- are rejected because they are reserved 'DebugSelection' spellings.
mkComponent ∷ Text → Either Text Component
mkComponent name
  | name == "all" || name == "none" =
      Left (rejected name "\"all\" and \"none\" are reserved Debug selectors")
  | Text.null name =
      Left (rejected name "a component name needs at least one segment")
  | any Text.null segments =
      Left (rejected name "every dot-separated segment must be nonempty")
  | Just bad ← find (not . validSegment) segments =
      Left (rejected name ("segment " <> quoted bad <> " must match [a-z][a-z0-9_-]*"))
  | otherwise = Right (Component name)
  where
    segments = Text.splitOn "." name

-- | Build a component from a name that is a literal in the source, failing
-- loudly with 'mkComponent'''s message when it is invalid. Use 'mkComponent'
-- for any name that comes from configuration, a file, or a user.
unsafeComponent ∷ HasCallStack ⇒ Text → Component
unsafeComponent name = either (error . Text.unpack) id (mkComponent name)

-- | The validated name, as it is matched and printed.
componentText ∷ Component → Text
componentText (Component name) = name

validSegment ∷ Text → Bool
validSegment segment = case Text.uncons segment of
  Nothing → False
  Just (leading, rest) → isAsciiLower leading && Text.all validTail rest
  where
    validTail character =
      isAsciiLower character || isDigit character || character == '_' || character == '-'

rejected ∷ Text → Text → Text
rejected name reason = "invalid component name " <> quoted name <> ": " <> reason

-- | Text as a double-quoted, escaped literal inside a message. Every diagnostic
-- that names text it rejected goes through this, so a value carrying a newline,
-- a quote, or any other control character cannot split the message across lines
-- or forge a second one. It is the same escaping the record layout applies (see
-- 'renderText'), and ordinary text is unchanged inside the quotes.
quoted ∷ Text → Text
quoted value = "\"" <> Text.concatMap escaped value <> "\""

-- | Which components may emit 'Debug' entries. A threshold never enables
-- 'Debug'; this selection is the only control that does.
data DebugSelection
  = DebugNone
  | DebugAll
  | DebugComponents !(Set Component)
  deriving (Eq, Show)

-- | Pure filter configuration. A logger applies one of these values; it is
-- never reconfigured in place.
--
-- Semantics, in order:
--
-- * 'filterEnabled' @False@ suppresses everything.
-- * A 'Debug' entry is emitted only when 'filterDebug' selects its component
--   or is 'DebugAll' — never because a threshold is set to 'Debug'.
-- * Any other level is emitted when it meets its component's own threshold
--   from 'filterComponentLevels', or 'filterGlobalLevel' when the component
--   has no entry there.
-- * 'filterSource' @False@ records no source location.
data LogFilter = LogFilter
  { filterEnabled ∷ !Bool
    -- ^ Master switch.
  , filterGlobalLevel ∷ !LogLevel
    -- ^ Threshold for components without an override.
  , filterComponentLevels ∷ !(Map Component LogLevel)
    -- ^ Exact per-component thresholds.
  , filterDebug ∷ !DebugSelection
    -- ^ The only control that enables 'Debug'.
  , filterSource ∷ !Bool
    -- ^ Whether an emitted entry records its call site.
  }
  deriving (Eq, Show)

-- | Enabled, global 'Info', no overrides, 'DebugNone', source enabled.
defaultLogFilter ∷ LogFilter
defaultLogFilter = LogFilter
  { filterEnabled = True
  , filterGlobalLevel = Info
  , filterComponentLevels = Map.empty
  , filterDebug = DebugNone
  , filterSource = True
  }

-- | Parse a threshold: @debug@, @info@, @warn@, @warning@, or @error@,
-- case-insensitively, with surrounding whitespace trimmed. An empty or
-- unrecognized value is an error, never a silent default.
parseLogLevel ∷ Text → Either Text LogLevel
parseLogLevel value = case Text.toLower trimmed of
  "debug" → Right Debug
  "info" → Right Info
  "warn" → Right Warning
  "warning" → Right Warning
  "error" → Right Error
  _
    | Text.null trimmed → Left ("a level is required: " <> levelForms)
    | otherwise → Left (invalid "level" trimmed levelForms)
  where
    trimmed = Text.strip value

levelForms ∷ Text
levelForms = "expected debug, info, warn, warning, or error"

-- | Parse exact per-component thresholds: a comma-separated list of
-- @component=level@ pairs whose component name and level are each trimmed, for
-- example @gpu.vulkan=warn,lua=info@.
--
-- A missing @=@, an empty entry, an empty value, a component name
-- 'mkComponent' rejects — internal whitespace included — and a component key
-- that appears twice are all errors. Matching stays exact: a key is the
-- validated name and nothing is normalized.
parseComponentLevels ∷ Text → Either Text (Map Component LogLevel)
parseComponentLevels value = do
  entries ← splitList "override list" overrideForms value
  pairs ← traverse pair entries
  foldM insert Map.empty pairs
  where
    pair entry
      | Text.null rest = Left (invalid "override" entry "expected component=level")
      | otherwise = do
          component ← mkComponent (Text.strip name)
          level ← either (const (Left (invalid "override" entry levelForms))) Right
                    (parseLogLevel (Text.drop 1 rest))
          Right (component, level)
      where
        (name, rest) = Text.breakOn "=" entry

    insert known (component, level)
      | Map.member component known =
          Left (invalid "override list" (Text.strip value)
                 ("component " <> quoted (componentText component) <> " appears twice"))
      | otherwise = Right (Map.insert component level known)

overrideForms ∷ Text
overrideForms = "expected a comma-separated list of component=level pairs"

-- | Parse a Debug selection: exactly lowercase @none@, exactly lowercase
-- @all@, or a comma-separated component list in which a repeated name collapses
-- to one entry.
--
-- Any other spelling of either selector, a selector combined with component
-- names, an empty entry, an empty value, and a name 'mkComponent' rejects are
-- all errors.
parseDebugSelection ∷ Text → Either Text DebugSelection
parseDebugSelection value
  | trimmed == "none" = Right DebugNone
  | trimmed == "all" = Right DebugAll
  | selector trimmed =
      Left (invalid "Debug selection" trimmed
             "the selectors \"all\" and \"none\" are spelled in lowercase")
  | otherwise = do
      entries ← splitList "Debug selection" debugForms value
      case find selector entries of
        Just reserved →
          Left (invalid "Debug selection" trimmed
                 (quoted reserved <> " cannot be combined with component names"))
        Nothing → DebugComponents . Set.fromList <$> traverse mkComponent entries
  where
    trimmed = Text.strip value

debugForms ∷ Text
debugForms = "expected none, all, or a comma-separated component list"

-- | Whether text is one of the two reserved selectors in any spelling, which
-- is what separates a bad spelling from a component name.
selector ∷ Text → Bool
selector value = lowered == "all" || lowered == "none"
  where
    lowered = Text.toLower value

-- | Split a comma-separated value and trim each entry, rejecting an empty
-- value or an empty entry rather than dropping it.
splitList ∷ Text → Text → Text → Either Text [Text]
splitList kind forms value
  | Text.null trimmed = Left ("a " <> kind <> " is required: " <> forms)
  | any Text.null entries = Left (invalid kind trimmed "an entry is empty")
  | otherwise = Right entries
  where
    trimmed = Text.strip value
    entries = map Text.strip (Text.splitOn "," trimmed)

invalid ∷ Text → Text → Text → Text
invalid kind value reason = "invalid " <> kind <> " " <> quoted value <> ": " <> reason

-- | The environment variable names an application reads its logging
-- configuration from. The names belong to the application: the parsers above
-- and 'resolveLogFilter' take values, so another application is free to use
-- another prefix over the same contract.
data LogVariables = LogVariables
  { variableGlobalLevel ∷ !Text
    -- ^ Supplies 'filterGlobalLevel'.
  , variableComponentLevels ∷ !Text
    -- ^ Supplies 'filterComponentLevels'.
  , variableDebug ∷ !Text
    -- ^ Supplies 'filterDebug'.
  }
  deriving (Eq, Show)

-- | Assemble a 'LogFilter' from a base configuration and a lookup, consulting
-- each of the three names exactly once, in a fixed order, and before any value
-- is parsed.
--
-- An absent value keeps the base configuration's own. A present but invalid one
-- yields a message naming the variable it came from, and the first such
-- variable in that order is the one reported. That message is always one line:
-- the rejected value is quoted and escaped, so a value carrying a newline
-- cannot forge a second line of output. 'filterEnabled' and 'filterSource' are
-- carried through untouched: they stay programmatic configuration with no
-- variable of their own.
--
-- The lookup performs whatever IO reading the environment needs; this function
-- performs none of its own, so a test supplies a pure, exhaustive, or counting
-- lookup instead.
resolveLogFilter
  ∷ Monad m
  ⇒ LogVariables → (Text → m (Maybe Text)) → LogFilter → m (Either Text LogFilter)
resolveLogFilter names lookupValue base = do
  global ← lookupValue (variableGlobalLevel names)
  overrides ← lookupValue (variableComponentLevels names)
  debug ← lookupValue (variableDebug names)
  pure $ do
    level ←
      configured (variableGlobalLevel names) parseLogLevel (filterGlobalLevel base) global
    levels ←
      configured (variableComponentLevels names) parseComponentLevels
        (filterComponentLevels base) overrides
    selection ←
      configured (variableDebug names) parseDebugSelection (filterDebug base) debug
    Right base
      { filterGlobalLevel = level
      , filterComponentLevels = levels
      , filterDebug = selection
      }
  where
    configured name parse fallback =
      maybe (Right fallback) (either (Left . named name) Right . parse)
    named name reason = name <> ": " <> reason

-- | The external call site an entry was emitted from. 'sourceFunction' names
-- the function whose call produced that site.
data SourceLocation = SourceLocation
  { sourceFile ∷ !Text
  , sourceLine ∷ !Int
  , sourceFunction ∷ !Text
  }
  deriving (Eq, Show)

-- | One emitted entry. Only entries that passed the filter are built, so every
-- field here is already paid for.
data LogEntry = LogEntry
  { entryLevel ∷ !LogLevel
  , entryComponent ∷ !Component
  , entryMessage ∷ !Text
  , entryFields ∷ !(Map Text Text)
    -- ^ Context fields of the logger, overridden by the event's own fields.
  , entryBreadcrumbs ∷ ![Text]
    -- ^ Context breadcrumbs in derivation order, outermost first.
  , entryTime ∷ !UTCTime
    -- ^ From 'metadataClock'.
  , entryThread ∷ !Text
    -- ^ From 'metadataThread'.
  , entrySource ∷ !(Maybe SourceLocation)
    -- ^ 'Nothing' when 'filterSource' is off.
  }
  deriving (Eq, Show)

-- | What a sink's records look like, and whether each one is flushed.
--
-- @formatFlush@ only decides whether the sink asks the handle to flush after
-- every record; it promises nothing about what an unflushed record is or is
-- not visible through, because the handle's buffering belongs to the caller.
data FormatOptions = FormatOptions
  { formatThread ∷ !Bool
    -- ^ Whether the @thread=@ segment is emitted. There is no separate
    -- thread-logging API; this option is the control.
  , formatFlush ∷ !Bool
    -- ^ Whether the sink flushes after every record.
  }
  deriving (Eq, Show)

-- | Thread segment on, per-entry flush on.
defaultFormatOptions ∷ FormatOptions
defaultFormatOptions = FormatOptions { formatThread = True, formatFlush = True }

-- | Render one entry as exactly one line, with no terminating newline: a sink
-- adds its own record terminator. Segments are separated by single spaces and
-- an absent optional segment is omitted entirely.
--
-- > <time> <LEVEL> <component> thread=<n> [src=<file>:<line>] [crumbs=<a>><b>] msg=<message> [<key>=<value> ...]
--
-- The time is UTC as ISO 8601 with exactly three fractional digits, truncating
-- finer precision, and a @Z@ suffix. @src=@ appears only for an entry carrying
-- a source location and @crumbs=@ only when there is at least one breadcrumb.
-- Fields follow the message, sorted by key.
--
-- Every piece of text in a record — message, breadcrumb, field key, field
-- value, source filename, and thread — goes through one rule, so nothing a
-- caller supplies can split a record or forge a segment. Text is written bare
-- when it is nonempty and holds only printable non-space characters other than
-- the four the layout reserves:
--
-- > " \ = >
--
-- Anything else is double-quoted, with these escapes inside the quotes:
--
-- > \" \\ \n \r \t
--
-- and every other control character written as a backslash, a @u@, and four
-- uppercase hex digits. Empty text renders as a pair of quotes.
--
-- A component name is validated before it can reach an entry, so it is always
-- bare. A field key is not, so it follows the same rule as everything else:
-- ordinary keys are bare, and only a key that would otherwise disturb the
-- layout is quoted.
formatEntry ∷ FormatOptions → LogEntry → Text
formatEntry options entry = Text.intercalate " " (concat parts)
  where
    parts =
      [ [formatTimestamp (entryTime entry)]
      , [levelName (entryLevel entry)]
      , [componentText (entryComponent entry)]
      , ["thread=" <> renderText (entryThread entry) | formatThread options]
      , foldMap (pure . sourceSegment) (entrySource entry)
      , [crumbSegment (entryBreadcrumbs entry) | not (null (entryBreadcrumbs entry))]
      , ["msg=" <> renderText (entryMessage entry)]
      , [ renderText key <> "=" <> renderText value
        | (key, value) ← Map.toAscList (entryFields entry)
        ]
      ]

    sourceSegment location =
      "src=" <> renderText (sourceFile location)
        <> ":" <> Text.pack (show (sourceLine location))

    crumbSegment crumbs = "crumbs=" <> Text.intercalate ">" (map renderText crumbs)

-- | UTC as ISO 8601 with millisecond precision. Sub-millisecond precision is
-- truncated rather than rounded, so the rendering of a timestamp never depends
-- on digits the layout does not show.
formatTimestamp ∷ UTCTime → Text
formatTimestamp time =
  Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" time)
    <> "." <> Text.justifyRight 3 '0' (Text.pack (show milliseconds))
    <> "Z"
  where
    milliseconds =
      (diffTimeToPicoseconds (utctDayTime time) `mod` 1000000000000) `div` 1000000000

-- | A text value as one layout segment: bare when that cannot disturb the
-- layout, and double-quoted with escapes otherwise.
renderText ∷ Text → Text
renderText value
  | not (Text.null value) && Text.all bare value = value
  | otherwise = quoted value
  where
    bare character =
      isPrint character
        && not (isSpace character)
        && character /= '"'
        && character /= '\\'
        && character /= '='
        && character /= '>'

escaped ∷ Char → Text
escaped '"' = "\\\""
escaped '\\' = "\\\\"
escaped '\n' = "\\n"
escaped '\r' = "\\r"
escaped '\t' = "\\t"
escaped character
  | isControl character = "\\u" <> hex4 (ord character)
  | otherwise = Text.singleton character

hex4 ∷ Int → Text
hex4 value = Text.pack (map nibble [4096, 256, 16, 1])
  where
    nibble place = "0123456789ABCDEF" !! ((value `div` place) `mod` 16)

levelName ∷ LogLevel → Text
levelName Debug = "DEBUG"
levelName Info = "INFO"
levelName Warning = "WARN"
levelName Error = "ERROR"

-- | Where emitted entries go, plus the flush that empties whatever the sink
-- writes through. Both are called synchronously on the emitting thread and
-- their exceptions propagate to the caller; a sink failure is never reported
-- back through the failing sink. The caller owns the sink's resources.
--
-- Build one with 'newHandleSink', 'newHandleSinkWith', 'callbackSink', or
-- 'callbackSinkWith'.
data LogSink = LogSink
  { sinkWrite ∷ !(LogEntry → IO ())
  , sinkFlush ∷ !(IO ())
  }

-- | 'newHandleSinkWith' with 'defaultFormatOptions'.
newHandleSink ∷ Handle → IO LogSink
newHandleSink = newHandleSinkWith defaultFormatOptions

-- | Borrow a handle. The sink writes each record as one whole line and never
-- closes the handle, changes its buffering, or outlives the caller's own
-- ownership of it; the handle stays usable after every logger sharing this
-- sink is discarded.
--
-- Writes and flushes are serialized across every logger sharing this sink, so
-- concurrent producers never interleave within a line and each producer's own
-- order is preserved. Ordering between threads is unspecified. That guarantee
-- is the sink value's, not the handle's: two roots sharing one handle must
-- share one sink, and constructing two handle sinks over one handle is
-- unsupported.
--
-- A failing or interrupted write releases the serialization state before the
-- exception leaves, so the next call on any sharing logger proceeds rather
-- than deadlocking. Such a write may leave a partial record; no transactional
-- file write is promised.
newHandleSinkWith ∷ FormatOptions → Handle → IO LogSink
newHandleSinkWith options handle = do
  ownership ← newMVar ()
  let serialized action = withMVar ownership (const action)
  pure LogSink
    { sinkWrite = \entry → serialized $ do
        Text.hPutStr handle (formatEntry options entry <> "\n")
        when (formatFlush options) (hFlush handle)
    , sinkFlush = serialized (hFlush handle)
    }

-- | 'callbackSinkWith' with a no-op flush, for a callback with no flushable
-- state of its own.
callbackSink ∷ (LogEntry → IO ()) → LogSink
callbackSink callback = callbackSinkWith callback (pure ())

-- | Wrap a caller-supplied callback and its flush action. The callback may
-- receive concurrent calls and supplies its own synchronization; it must not
-- emit to the same sink recursively. Exceptions from either action propagate
-- like any other sink failure.
callbackSinkWith ∷ (LogEntry → IO ()) → IO () → LogSink
callbackSinkWith callback flush = LogSink { sinkWrite = callback, sinkFlush = flush }

-- | Forward an already-prepared entry to a sink, exactly as 'logEvent' forwards
-- the one it built.
--
-- The write is synchronous on the calling thread and its exceptions propagate
-- to that caller, like every other sink write. No filter is applied and no
-- metadata is obtained: the entry is emitted as it stands, so an entry carried
-- across a thread boundary keeps the level, component, context, timestamp,
-- thread identity, and source attribution it was built with.
writeEntry ∷ LogSink → LogEntry → IO ()
writeEntry = sinkWrite

-- | Flush a sink directly, for a caller that holds the sink rather than a
-- logger over it. 'flushLogger' is this operation on a logger's own sink, and
-- both fail the same way.
flushSink ∷ LogSink → IO ()
flushSink = sinkFlush

-- | The metadata an entry cannot derive from its call. Injected so tests can
-- supply fixed values and observe that a suppressed entry calls neither.
data MetadataProviders = MetadataProviders
  { metadataClock ∷ IO UTCTime
  , metadataThread ∷ IO Text
  }

-- | The real providers: the system UTC clock and this thread's numeric GHC
-- identity, which is what the @thread=@ segment of the layout shows.
systemMetadata ∷ MetadataProviders
systemMetadata = MetadataProviders
  { metadataClock = getCurrentTime
  , metadataThread = threadIdentity <$> myThreadId
  }

-- | The number out of @ThreadId 7@, so the layout carries the identity rather
-- than its @Show@ spelling.
threadIdentity ∷ ThreadId → Text
threadIdentity = Text.pack . dropWhile (not . isDigit) . show

-- | An opaque logger. 'mkLoggerWith' is the only way to build one, so every
-- logger applies a filter and owns its context; 'withFields' and
-- 'withBreadcrumb' derive new ones without touching the parent.
data Logger = Logger
  { loggerFilter ∷ !LogFilter
  , loggerMetadata ∷ !MetadataProviders
  , loggerSink ∷ !LogSink
  , loggerFields ∷ !(Map Text Text)
  , loggerBreadcrumbs ∷ ![Text]
  }

-- | Build a logger from a filter, metadata providers, and a sink. The logger
-- starts with no context fields and no breadcrumbs.
mkLoggerWith ∷ LogFilter → MetadataProviders → LogSink → Logger
mkLoggerWith configuration providers sink = Logger
  { loggerFilter = configuration
  , loggerMetadata = providers
  , loggerSink = sink
  , loggerFields = Map.empty
  , loggerBreadcrumbs = []
  }

-- | 'mkLoggerWith' with the production 'systemMetadata' providers.
mkLogger ∷ LogFilter → LogSink → Logger
mkLogger configuration = mkLoggerWith configuration systemMetadata

-- | A production logger writing to a borrowed handle through 'newHandleSink'.
-- Derive every other logger over that handle from this one, or share its sink
-- explicitly: a second handle sink over the same handle serializes against
-- nothing.
handleLogger ∷ LogFilter → Handle → IO Logger
handleLogger configuration handle = mkLogger configuration <$> newHandleSink handle

-- | Derive a logger carrying additional immutable context fields, sharing the
-- parent's filter, providers, and sink. These fields override fields of the
-- same key inherited from the parent, and a later pair in the list overrides an
-- earlier one. The parent is unchanged.
withFields ∷ [(Text, Text)] → Logger → Logger
withFields fields logger =
  logger { loggerFields = Map.union (Map.fromList fields) (loggerFields logger) }

-- | Derive a logger with one more breadcrumb appended, so breadcrumbs read in
-- derivation order. The parent is unchanged.
withBreadcrumb ∷ Text → Logger → Logger
withBreadcrumb breadcrumb logger =
  logger { loggerBreadcrumbs = loggerBreadcrumbs logger <> [breadcrumb] }

-- | Flush this logger's sink, whether or not the sink flushes every entry.
-- Derived loggers share their root's sink, so flushing any one of them flushes
-- what all of them wrote. Failures propagate like any other sink failure.
flushLogger ∷ Logger → IO ()
flushLogger = flushSink . loggerSink

-- | The single emission path. The filter decides before @message@ or @fields@
-- are forced and before either metadata provider runs. Event fields override
-- the logger's context fields.
logEvent
  ∷ HasCallStack
  ⇒ Logger → LogLevel → Component → Text → [(Text, Text)] → IO ()
logEvent logger level component message fields =
  when (emits (loggerFilter logger) level component) $ do
    now ← metadataClock (loggerMetadata logger)
    thread ← metadataThread (loggerMetadata logger)
    let entry = LogEntry
          { entryLevel = level
          , entryComponent = component
          , entryMessage = message
          , entryFields = Map.union (Map.fromList fields) (loggerFields logger)
          , entryBreadcrumbs = loggerBreadcrumbs logger
          , entryTime = now
          , entryThread = thread
          , entrySource =
              if filterSource (loggerFilter logger) then callSite callStack else Nothing
          }
    writeEntry (loggerSink logger) entry

-- | Emit at 'Debug' through 'logEvent'.
logDebug ∷ HasCallStack ⇒ Logger → Component → Text → [(Text, Text)] → IO ()
logDebug logger = withFrozenCallStack (logEvent logger Debug)

-- | Emit at 'Info' through 'logEvent'.
logInfo ∷ HasCallStack ⇒ Logger → Component → Text → [(Text, Text)] → IO ()
logInfo logger = withFrozenCallStack (logEvent logger Info)

-- | Emit at 'Warning' through 'logEvent'.
logWarning ∷ HasCallStack ⇒ Logger → Component → Text → [(Text, Text)] → IO ()
logWarning logger = withFrozenCallStack (logEvent logger Warning)

-- | Emit at 'Error' through 'logEvent'. Logging an error raises nothing by
-- itself; only a failing sink throws.
logError ∷ HasCallStack ⇒ Logger → Component → Text → [(Text, Text)] → IO ()
logError logger = withFrozenCallStack (logEvent logger Error)

emits ∷ LogFilter → LogLevel → Component → Bool
emits configuration level component
  | not (filterEnabled configuration) = False
  | level == Debug = debugSelected (filterDebug configuration) component
  | otherwise = level >= threshold
  where
    threshold =
      Map.findWithDefault
        (filterGlobalLevel configuration)
        component
        (filterComponentLevels configuration)

debugSelected ∷ DebugSelection → Component → Bool
debugSelected DebugNone _ = False
debugSelected DebugAll _ = True
debugSelected (DebugComponents selected) component = Set.member component selected

-- | The outermost frame is the call site outside every function that declared
-- the call-stack constraint, which keeps attribution on a wrapper's caller
-- rather than inside the wrapper.
callSite ∷ CallStack → Maybe SourceLocation
callSite stack = case reverse (getCallStack stack) of
  [] → Nothing
  ((name, location) : _) → Just SourceLocation
    { sourceFile = Text.pack (srcLocFile location)
    , sourceLine = srcLocStartLine location
    , sourceFunction = Text.pack name
    }
