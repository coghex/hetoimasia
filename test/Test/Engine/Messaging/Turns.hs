-- | The bounded-turn example: a custom multi-input loop an application writes
-- from the public channel and snapshot operations.
--
-- Nothing here is an engine scheduling or batching interface. The loop is the
-- example's own: each input has an explicit, finite per-turn budget, and every
-- dequeued entry costs one opportunity whether it is handled, rejected, or
-- discarded, so one continuously ready input cannot starve the others. It runs
-- on one thread with every input already ready, so no coordination is needed
-- and no example sleeps.
module Test.Engine.Messaging.Turns (spec) where

import Control.Concurrent.STM (atomically, orElse)
import Control.Monad (forM, unless)
import Data.Foldable (traverse_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Channel
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( SnapshotCursor
  , SnapshotReader
  , Update (..)
  , awaitSnapshot
  , newSnapshot
  , observedCursor
  , observedValue
  , publish
  , readSnapshot
  , snapshotReader
  )
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe)

spec ∷ Spec
spec = describe "Bounded turns" $
  it "serves every input under continuously ready traffic, charging rejected and discarded entries their opportunity"
    testBoundedTurns

-- | One input of the loop: its per-turn budget and one opportunity. An
-- opportunity describes what it did, or returns 'Nothing' when nothing was
-- ready, which ends that input's turn early.
data Input = Input !Int (IO (Maybe Text))

-- | One turn: every input in order, each for at most its budget.
runTurn ∷ [Input] → IO [Text]
runTurn = fmap concat . traverse serve
  where
    serve (Input budget opportunity) = go budget
      where
        go remaining
          | remaining <= 0 = pure []
          | otherwise = opportunity >>= maybe (pure []) (\served → (served :) <$> go (remaining - 1))

-- | Receive one entry without waiting. A dequeued entry the verdict refuses is
-- still dequeued, and still reported as this opportunity.
fromChannel ∷ Text → (Int → Maybe Text) → Receiver Int → IO (Maybe Text)
fromChannel name refusal receiver =
  atomically (receive receiver) >>= \case
    Received payload →
      let value = preparedValue payload
       in pure (Just (name <> " " <> showText value <> maybe "" (" " <>) (refusal value)))
    Empty → pure Nothing
    Terminated _ → pure Nothing

-- | Take the newest unseen publication without waiting.
fromSnapshot ∷ Text → SnapshotReader Int → IORef (SnapshotCursor Int) → IO (Maybe Text)
fromSnapshot name reader seen = do
  cursor ← readIORef seen
  atomically ((Just <$> awaitSnapshot reader cursor) `orElse` pure Nothing) >>= \case
    Just (Updated observation) → do
      writeIORef seen (observedCursor observation)
      pure (Just (name <> " " <> showText (preparedValue (observedValue observation))))
    _ → pure Nothing

testBoundedTurns ∷ Expectation
testBoundedTurns = do
  commands ← newChannel 16
  events ← newChannel 16
  let fill channel = traverse_ $ \value → do
        sent ← prepare value >>= atomically . send (channelSender channel)
        unless (sent == Accepted) (expectationFailure ("expected " <> show value <> " to be accepted"))
  -- Commands alone could fill every turn: far more are queued than the example
  -- ever takes, and a negative command is rejected. An event of zero is stale
  -- and discarded.
  fill commands [1, -2, 3, 4, 5, -6, 7, 8, 9, 10]
  fill events [10, 0, 30, 40]
  settings ← newSnapshot =<< prepare (0 ∷ Int)
  let reader = snapshotReader settings
  seen ← newIORef . observedCursor =<< atomically (readSnapshot reader)
  let inputs =
        [ Input 2 (fromChannel "command" (\value → if value < 0 then Just "rejected" else Nothing) (channelReceiver commands))
        , Input 1 (fromChannel "event" (\value → if value == 0 then Just "discarded" else Nothing) (channelReceiver events))
        , Input 1 (fromSnapshot "settings" reader seen)
        ]
  turns ← forM [1, 2, 3 ∷ Int] $ \turn → do
    -- A fresh publication before every turn keeps the snapshot ready too.
    _ ← prepare (turn * 100) >>= atomically . publish settings
    runTurn inputs
  turns
    `shouldBe` [ ["command 1", "command -2 rejected", "event 10", "settings 100"]
               , ["command 3", "command 4", "event 0 discarded", "settings 200"]
               , ["command 5", "command -6 rejected", "event 30", "settings 300"]
               ]
  -- Each dequeued entry was one opportunity: two commands and one event a
  -- turn, with the rest still queued and ready.
  commandCounts ← atomically (channelStatistics commands)
  eventCounts ← atomically (channelStatistics events)
  (statisticsDequeued commandCounts, statisticsDepth commandCounts) `shouldBe` (6, 4)
  (statisticsDequeued eventCounts, statisticsDepth eventCounts) `shouldBe` (3, 1)

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show
