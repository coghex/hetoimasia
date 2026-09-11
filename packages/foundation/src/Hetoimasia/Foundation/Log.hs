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
-- See @docs/logging.md@ for the same contract in prose.
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

    -- * Sinks
  , LogSink
  , handleSink

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

    -- * Emission
  , logEvent
  , logDebug
  , logInfo
  , logWarning
  , logError
  ) where

import Control.Concurrent (myThreadId)
import Control.Monad (when)
import Data.Char (isAsciiLower, isDigit)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Stack
  ( CallStack
  , HasCallStack
  , callStack
  , getCallStack
  , srcLocFile
  , srcLocStartLine
  , withFrozenCallStack
  )
import System.IO (Handle)

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

-- | Where emitted entries go. Called synchronously on the emitting thread;
-- exceptions propagate to the caller. The caller owns the sink's resources and
-- any concurrency policy.
type LogSink = LogEntry → IO ()

-- | Borrow a handle, writing one line per entry. The sink neither closes the
-- handle nor changes its buffering. The layout is provisional: a message
-- containing newlines is not escaped, so it does not stay on one physical
-- line.
handleSink ∷ Handle → LogSink
handleSink handle = Text.hPutStrLn handle . formatEntry

formatEntry ∷ LogEntry → Text
formatEntry entry =
  "[" <> levelName (entryLevel entry) <> "] "
    <> componentText (entryComponent entry) <> ": " <> entryMessage entry

levelName ∷ LogLevel → Text
levelName Debug = "DEBUG"
levelName Info = "INFO"
levelName Warning = "WARN"
levelName Error = "ERROR"

-- | The metadata an entry cannot derive from its call. Injected so tests can
-- supply fixed values and observe that a suppressed entry calls neither.
data MetadataProviders = MetadataProviders
  { metadataClock ∷ IO UTCTime
  , metadataThread ∷ IO Text
  }

-- | The real providers: the system UTC clock and this thread's identity.
systemMetadata ∷ MetadataProviders
systemMetadata = MetadataProviders
  { metadataClock = getCurrentTime
  , metadataThread = Text.pack . show <$> myThreadId
  }

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

-- | A production logger writing to a borrowed handle through 'handleSink'.
handleLogger ∷ LogFilter → Handle → Logger
handleLogger configuration = mkLogger configuration . handleSink

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
    loggerSink logger entry

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
