-- | Fixtures shared by the logging examples.
--
-- Everything here is a value or a freshly constructed collector: a helper hands
-- each caller its own state, so no example can observe another's. They belong
-- to the logging examples alone; the runtime examples construct their own
-- logger fixture, and the bounded wait comes from "Test.Support.Bounded".
module Test.Engine.Logging.Support
  ( testComponent
  , gpuComponent
  , gameComponent
  , luaComponent
  , fixedTime
  , fixedThread
  , fixedMetadata
  , newCollector
  , summaries
  ) where

import Control.Concurrent.MVar (modifyMVar_, newMVar, readMVar)
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log

testComponent ∷ Component
testComponent = unsafeComponent "test"

gpuComponent ∷ Component
gpuComponent = unsafeComponent "gpu.vulkan"

gameComponent ∷ Component
gameComponent = unsafeComponent "game.world"

luaComponent ∷ Component
luaComponent = unsafeComponent "lua"

fixedTime ∷ UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 10) (secondsToDiffTime 43200)

-- | The layout shows the numeric GHC thread identity, so a fixture supplies a
-- number rather than a @Show@ spelling.
fixedThread ∷ Text
fixedThread = "3"

-- | Providers returning values a test can assert on exactly.
fixedMetadata ∷ MetadataProviders
fixedMetadata = MetadataProviders
  { metadataClock = pure fixedTime
  , metadataThread = pure fixedThread
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
