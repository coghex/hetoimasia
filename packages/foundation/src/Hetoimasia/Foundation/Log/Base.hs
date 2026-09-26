-- | The elementary logging types: severity, the call-site record, and the two
-- small option records the formatter and the startup configuration take.
--
-- This module depends on nothing else in the logging family. Failure
-- attribution imports 'SourceLocation' from here, so an origin site needs no
-- logger, filter, or sink. The public facade is "Hetoimasia.Foundation.Log";
-- this module is private to the foundation package.
module Hetoimasia.Foundation.Log.Base
  ( -- * Severity
    LogLevel (..)

    -- * Call sites
  , SourceLocation (..)

    -- * Options
  , FormatOptions (..)
  , defaultFormatOptions
  , LogVariables (..)
  ) where

import Data.Text (Text)

-- | Severity, ordered from most to least detailed. The ordering is used for
-- threshold comparisons; 'Debug' is never selected by a threshold (see
-- 'Hetoimasia.Foundation.Log.LogFilter').
data LogLevel = Debug | Info | Warning | Error
  deriving (Eq, Ord, Show)

-- | The external call site an entry was emitted from. 'sourceFunction' names
-- the function whose call produced that site.
data SourceLocation = SourceLocation
  { sourceFile ∷ !Text
  , sourceLine ∷ !Int
  , sourceFunction ∷ !Text
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

-- | The environment variable names an application reads its logging
-- configuration from. The names belong to the application: the parsers and
-- 'Hetoimasia.Foundation.Log.resolveLogFilter' take values, so another
-- application is free to use another prefix over the same contract.
data LogVariables = LogVariables
  { variableGlobalLevel ∷ !Text
    -- ^ Supplies 'Hetoimasia.Foundation.Log.filterGlobalLevel'.
  , variableComponentLevels ∷ !Text
    -- ^ Supplies 'Hetoimasia.Foundation.Log.filterComponentLevels'.
  , variableDebug ∷ !Text
    -- ^ Supplies 'Hetoimasia.Foundation.Log.filterDebug'.
  }
  deriving (Eq, Show)
