-- | The composite logging records: filter configuration, entries, sinks,
-- metadata providers, and loggers.
--
-- These are built from "Hetoimasia.Foundation.Log.Base" and
-- "Hetoimasia.Foundation.Log.Component" alone. The operations over them live
-- beside their responsibility: parsing and admission in
-- "Hetoimasia.Foundation.Log.Filter", the record layout in
-- "Hetoimasia.Foundation.Log.Format", sink construction and serialized writes
-- in "Hetoimasia.Foundation.Log.Sink", and logger derivation and emission in
-- "Hetoimasia.Foundation.Log".
--
-- The 'LogSink' and 'Logger' constructors are exported so those modules can
-- build and read them. This module is private to the foundation package, and
-- the public facade exports both types abstractly.
module Hetoimasia.Foundation.Log.Types
  ( -- * Filter configuration
    DebugSelection (..)
  , LogFilter (..)
  , defaultLogFilter

    -- * Entries
  , LogEntry (..)

    -- * Sinks
  , LogSink (..)

    -- * Metadata providers
  , MetadataProviders (..)

    -- * Loggers
  , Logger (..)
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Hetoimasia.Foundation.Log.Base (LogLevel (..), SourceLocation)
import Hetoimasia.Foundation.Log.Component (Component)

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

-- | Where emitted entries go, plus the flush that empties whatever the sink
-- writes through. Both are called synchronously on the emitting thread and
-- their exceptions propagate to the caller; a sink failure is never reported
-- back through the failing sink. The caller owns the sink's resources.
--
-- Build one with 'Hetoimasia.Foundation.Log.newHandleSink',
-- 'Hetoimasia.Foundation.Log.newHandleSinkWith',
-- 'Hetoimasia.Foundation.Log.callbackSink', or
-- 'Hetoimasia.Foundation.Log.callbackSinkWith'.
data LogSink = LogSink
  { sinkWrite ∷ !(LogEntry → IO ())
  , sinkFlush ∷ !(IO ())
  }

-- | The metadata an entry cannot derive from its call. Injected so tests can
-- supply fixed values and observe that a suppressed entry calls neither.
data MetadataProviders = MetadataProviders
  { metadataClock ∷ IO UTCTime
  , metadataThread ∷ IO Text
  }

-- | An opaque logger. 'Hetoimasia.Foundation.Log.mkLoggerWith' is the only way
-- to build one, so every logger applies a filter and owns its context;
-- 'Hetoimasia.Foundation.Log.withFields' and
-- 'Hetoimasia.Foundation.Log.withBreadcrumb' derive new ones without touching
-- the parent.
data Logger = Logger
  { loggerFilter ∷ !LogFilter
  , loggerMetadata ∷ !MetadataProviders
  , loggerSink ∷ !LogSink
  , loggerFields ∷ !(Map Text Text)
  , loggerBreadcrumbs ∷ ![Text]
  }
