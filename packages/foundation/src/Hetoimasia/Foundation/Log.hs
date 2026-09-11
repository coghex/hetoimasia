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
import Control.Monad (when)
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

quoted ∷ Text → Text
quoted value = "\"" <> value <> "\""

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
  | otherwise = "\"" <> Text.concatMap escaped value <> "\""
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
flushLogger = sinkFlush . loggerSink

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
    sinkWrite (loggerSink logger) entry

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
