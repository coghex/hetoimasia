-- | The small logger fixture the runtime examples construct for themselves.
--
-- It is built only from the public "Hetoimasia.Foundation.Log" API, so the
-- runtime examples do not borrow the foundation logging suite's own helpers.
-- Everything here is a value or a freshly constructed collector: each caller
-- gets its own state, so no example can observe another's.
module Test.Runtime.LogFixture
  ( fixedMetadata
  , newCollector
  , summaries
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log

-- | Providers returning values an example can assert on exactly.
fixedMetadata ∷ MetadataProviders
fixedMetadata = MetadataProviders
  { metadataClock = pure (UTCTime (fromGregorian 2026 9 10) (secondsToDiffTime 43200))
  , metadataThread = pure "3"
  }

-- | A sink collecting entries in emission order, usable from several threads.
newCollector ∷ IO (LogSink, IO [LogEntry])
newCollector = do
  collected ← newMVar []
  let sink entry = modifyMVar_ collected (pure . (entry :))
  pure (callbackSink sink, reverse <$> readMVar collected)

-- | Level, component, and message of each entry, ignoring metadata.
summaries ∷ [LogEntry] → [(LogLevel, Text, Text)]
summaries = map summary
  where
    summary entry =
      (entryLevel entry, componentText (entryComponent entry), entryMessage entry)
