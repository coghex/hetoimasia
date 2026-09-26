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
-- This module is the supported interface. It defines the logger operations —
-- construction, scoped context, flushing, emission, and call-site extraction —
-- and re-exports the rest from private modules of the foundation package, each
-- owning one responsibility:
--
-- * @Hetoimasia.Foundation.Log.Base@: 'LogLevel', 'SourceLocation',
--   'FormatOptions', and 'LogVariables'.
-- * @Hetoimasia.Foundation.Log.Component@: the validated 'Component' and the
--   quoting its diagnostics and the record layout share.
-- * @Hetoimasia.Foundation.Log.Types@: the filter, entry, sink, metadata, and
--   logger records.
-- * @Hetoimasia.Foundation.Log.Filter@: startup parsing and admission.
-- * @Hetoimasia.Foundation.Log.Format@: the record layout and escaping.
-- * @Hetoimasia.Foundation.Log.Sink@: handle and callback sinks, and
--   forwarding to one.
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
import Control.Monad (when)
import Data.Char (isDigit)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (getCurrentTime)
import GHC.Stack
  ( CallStack
  , HasCallStack
  , callStack
  , getCallStack
  , srcLocFile
  , srcLocStartLine
  , withFrozenCallStack
  )
import Hetoimasia.Foundation.Log.Base
  ( FormatOptions (..)
  , LogLevel (..)
  , LogVariables (..)
  , SourceLocation (..)
  , defaultFormatOptions
  )
import Hetoimasia.Foundation.Log.Component
  ( Component
  , componentText
  , mkComponent
  , unsafeComponent
  )
import Hetoimasia.Foundation.Log.Filter
  ( emits
  , parseComponentLevels
  , parseDebugSelection
  , parseLogLevel
  , resolveLogFilter
  )
import Hetoimasia.Foundation.Log.Format (formatEntry)
import Hetoimasia.Foundation.Log.Sink
  ( callbackSink
  , callbackSinkWith
  , flushSink
  , newHandleSink
  , newHandleSinkWith
  , writeEntry
  )
import Hetoimasia.Foundation.Log.Types
  ( DebugSelection (..)
  , LogEntry (..)
  , LogFilter (..)
  , LogSink
  , Logger (..)
  , MetadataProviders (..)
  , defaultLogFilter
  )
import System.IO (Handle)

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
