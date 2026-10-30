-- | A bounded log of events with a monotonic cursor: what a native example waits on after a mark it took.
--
-- The storage is bounded (the newest 'frameLogLimit' events), but a mark is the count of events ever recorded, not an
-- index into what is retained, so a mark taken long ago still means "events after that one", and a log that has
-- rolled over answers the events it still holds that came after the mark.
module Test.LuaEngine.Graphics.FrameLog
  ( FrameLog
  , emptyFrameLog
  , frameLogLimit
  , recordEvent
  , frameLogMark
  , eventsSince
  ) where

-- | The count of events ever recorded and the newest of them, newest first.
data FrameLog a = FrameLog !Int [a]

emptyFrameLog ∷ FrameLog a
emptyFrameLog = FrameLog 0 []

-- | How many events are retained.
frameLogLimit ∷ Int
frameLogLimit = 4096

recordEvent ∷ a → FrameLog a → FrameLog a
recordEvent event (FrameLog total recent) = FrameLog (total + 1) (take frameLogLimit (event : recent))

-- | The mark that means "everything recorded from now on".
frameLogMark ∷ FrameLog a → Int
frameLogMark (FrameLog total _) = total

-- | The retained events recorded after this mark, newest first.
eventsSince ∷ Int → FrameLog a → [a]
eventsSince mark (FrameLog total recent) = take (max 0 (total - mark)) recent
