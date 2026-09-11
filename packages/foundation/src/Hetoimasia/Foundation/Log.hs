-- | Synchronous logging through an explicit, injectable sink.
-- The caller owns the sink's resources and any concurrency policy.
module Hetoimasia.Foundation.Log
  ( Logger
  , LogLevel (..)
  , LogEntry (..)
  , mkLogger
  , handleLogger
  , logMessage
  ) where

import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.IO (Handle)

data LogLevel = Debug | Info | Warning | Error
  deriving (Eq, Ord, Show)

data LogEntry = LogEntry
  { entryLevel ∷ !LogLevel
  , entryComponent ∷ !Text
  , entryMessage ∷ !Text
  }
  deriving (Eq, Show)

-- | The constructor stays private so every logger applies its policy.
newtype Logger = Logger (LogEntry → IO ())

-- | Entries below the threshold never reach the sink. Sink exceptions propagate.
mkLogger ∷ LogLevel → (LogEntry → IO ()) → Logger
mkLogger minimumLevel sink = Logger $ \entry →
  when (entryLevel entry >= minimumLevel) (sink entry)

-- | Borrow a handle; the logger neither closes it nor changes its buffering.
handleLogger ∷ LogLevel → Handle → Logger
handleLogger minimumLevel handle =
  mkLogger minimumLevel (Text.hPutStrLn handle . formatEntry)

logMessage ∷ Logger → LogLevel → Text → Text → IO ()
logMessage (Logger sink) level component message =
  sink (LogEntry level component message)

formatEntry ∷ LogEntry → Text
formatEntry entry =
  "[" <> levelName (entryLevel entry) <> "] "
    <> entryComponent entry <> ": " <> entryMessage entry

levelName ∷ LogLevel → Text
levelName Debug = "DEBUG"
levelName Info = "INFO"
levelName Warning = "WARN"
levelName Error = "ERROR"
