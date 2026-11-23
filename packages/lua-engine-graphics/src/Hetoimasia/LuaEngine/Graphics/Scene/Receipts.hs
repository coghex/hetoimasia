{-# LANGUAGE LambdaCase #-}

-- | Draw receipts (TRA-9, D-7): which terrain-view revision a target actually drew, and with which metrics.
--
-- = When a receipt moves
--
-- A receipt names the 'WorldTag' of the revision drawn (the view incarnation, which is bound to one target
-- incarnation, and its plan revision) and the metrics of the frame that drew it. It advances only at the boundary where a drawing is real:
--
-- * a window: the successful enqueue of the frame's presentation. The renderer records what a frame of a world
--   scene is about to draw ('noteRecorded', keyed by the frame's attachment and slot), and the host's frame observer
--   ('receiptObserver') promotes it when the present call enqueued it, or forgets it when the frame was abandoned;
-- * a registered offscreen target: the batch that recorded it. The owner action that records it notes the batch's
--   ticket ('noteOffscreenBatch'), and the observer promotes it once the ticket reports the batch complete (which only
--   a submitted batch becomes), in the order the batches were noted; a discarded or lost batch drew nothing. Nothing
--   of this rests on the caller that asked for the drawing.
--
-- Adoption alone, a recording, a refused or abandoned frame and a frame of an M1 scene leave the receipt as it
-- was. Only a live view incarnation's receipt moves: a view is registered at its open ('openReceipt') and forgotten at
-- its close ('forgetReceipt'), which also drops whatever of it was recorded and not yet promoted.
--
-- Frame metrics are kept for the most recently drawn window attachments, at most 'metricsKept' of them, so a window
-- already showing a scene has its metrics when a view opens on it and window churn leaves a bounded record. An
-- attachment a view watches ('watchFrameMetrics', from its open to its close) is never evicted.
--
-- = Owned state, threads and lifetime
--
-- +-----------------+-----------------+---------------------------------------+---------------------+------------------+
-- | State           | Owner           | Writers                               | Readers             | Lifetime         |
-- +=================+=================+=======================================+=====================+==================+
-- | Recorded frames | the scene       | the renderer and the frame observer,  | the observer        | from a world     |
-- | (by attachment  | session         | on the graphics owner's thread (STM)  |                     | frame's recording|
-- | and slot)       |                 |                                       |                     | to its present   |
-- |                 |                 |                                       |                     | or abandonment   |
-- +-----------------+-----------------+---------------------------------------+---------------------+------------------+
-- | Receipts (by    | the scene       | the observer, an offscreen recording's| any thread (STM)    | until the view's |
-- | view)           | session         | caller, a view's close                |                     | close forgets it |
-- +-----------------+-----------------+---------------------------------------+---------------------+------------------+
-- | Frame events    | the scene       | the observer                          | any thread (STM)    | the session's    |
-- | (two counts)    | session         |                                       |                     |                  |
-- +-----------------+-----------------+---------------------------------------+---------------------+------------------+
--
-- A recorded frame lives only between two events the host reports for the same frame slot, so at most one is kept
-- per attachment and slot; a recording the host never reports again is replaced by the slot's next recording. The
-- observer runs one transaction per event and neither waits nor raises. It counts every frame event, and every
-- presentation's enqueue, and runs no holder's code: a holder that acts on frames, as the terrain views do, watches
-- the counts in a transaction of its own ('receiptsFrames'). An offscreen batch is noted by its native ticket, which
-- the receipts read through the backend's own reader.
module Hetoimasia.LuaEngine.Graphics.Scene.Receipts
  ( DrawReceipts
  , newDrawReceipts
  , Drawn (..)
  , readReceipt
  , openReceipt
  , forgetReceipt
  , noteRecorded
  , noteUnrecorded
  , noteSubmitted
  , noteOffscreenBatch
  , receiptObserver
  , sweepOffscreen
  , offscreenSweepDue
  , receiptsFrames
  , watchFrameMetrics
  , unwatchFrameMetrics
  , noteFrameMetrics
  , latestFrameMetrics
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, stateTVar, writeTVar)
import Control.Monad (when)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.GPU.Model.Identity (FrameSlotId)
import Hetoimasia.GPU.Vulkan.GLFW (BatchTicket, FrameEvent (..), FrameObserver, TicketState (..), readTicket)
import Hetoimasia.LuaEngine.Graphics.Scene.World (WorldTag (..))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)
import Hetoimasia.Runtime.GLFW (AttachmentId)
import Numeric.Natural (Natural)

-- | What a view's target drew: the revision and the metrics of the frame, and a count that moves with every drawing
-- of the view, so a reader can tell two drawings of one revision apart.
data Drawn = Drawn
  { drawnTag ∷ !WorldTag
  , drawnMetrics ∷ !TargetMetrics
  , drawnCount ∷ !Natural
  }
  deriving (Eq, Show)

-- | The session's receipts.
data DrawReceipts = DrawReceipts
  { receiptsRecorded ∷ !(TVar (Map (AttachmentId, FrameSlotId) (WorldTag, TargetMetrics)))
  , receiptsOffscreen ∷ !(TVar (Seq (BatchTicket, WorldTag, TargetMetrics)))
    -- ^ Offscreen batches noted and not yet settled, in the order they were noted.
  , receiptsDrawn ∷ !(TVar (Map Word64 Drawn))
  , receiptsLive ∷ !(TVar (Set Word64))
    -- ^ The view incarnations whose receipts may move.
  , receiptsEvents ∷ !(TVar (Natural, Natural))
    -- ^ How many frame events the observer has seen, and how many of them were a presentation's enqueue.
  , receiptsMetrics ∷ !(TVar (Map AttachmentId (TargetMetrics, Natural)))
    -- ^ The metrics of each kept attachment's latest recorded frame, with when it was noted.
  , receiptsWatched ∷ !(TVar (Map AttachmentId Natural))
    -- ^ How many views watch each attachment.
  , receiptsClock ∷ !(TVar Natural)
  }

-- | How many window attachments' metrics are kept beyond the watched ones.
metricsKept ∷ Int
metricsKept = 64

newDrawReceipts ∷ IO DrawReceipts
newDrawReceipts =
  DrawReceipts <$> newTVarIO Map.empty <*> newTVarIO Seq.empty <*> newTVarIO Map.empty <*> newTVarIO Set.empty <*> newTVarIO (0, 0) <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO 0

-- | The view incarnation's latest receipt, if it has drawn.
readReceipt ∷ DrawReceipts → Word64 → STM (Maybe Drawn)
readReceipt receipts view = Map.lookup view <$> readTVar (receiptsDrawn receipts)

-- | A view incarnation opens: its receipt may move from now on.
openReceipt ∷ DrawReceipts → Word64 → STM ()
openReceipt receipts view = modifyTVar' (receiptsLive receipts) (Set.insert view)

-- | A view incarnation closes: its receipt, and whatever of it was recorded and not yet promoted, go.
forgetReceipt ∷ DrawReceipts → Word64 → STM ()
forgetReceipt receipts view = do
  modifyTVar' (receiptsLive receipts) (Set.delete view)
  modifyTVar' (receiptsDrawn receipts) (Map.delete view)
  modifyTVar' (receiptsRecorded receipts) (Map.filter (\(tag, _) → tagView tag /= view))
  modifyTVar' (receiptsOffscreen receipts) (Seq.filter (\(_, tag, _) → tagView tag /= view))

-- | A frame of a world scene was recorded for this attachment and slot: what it will have drawn if its presentation
-- is enqueued. Called by the renderer on the graphics owner's thread.
noteRecorded ∷ DrawReceipts → AttachmentId → FrameSlotId → WorldTag → TargetMetrics → STM ()
noteRecorded receipts attachment slot tag metrics = do
  live ← Set.member (tagView tag) <$> readTVar (receiptsLive receipts)
  if live
    then modifyTVar' (receiptsRecorded receipts) (Map.insert (attachment, slot) (tag, metrics))
    else noteUnrecorded receipts attachment slot

-- | A frame of anything but a live view's world scene was recorded for this attachment and slot: it draws nothing a
-- receipt names.
noteUnrecorded ∷ DrawReceipts → AttachmentId → FrameSlotId → STM ()
noteUnrecorded receipts attachment slot = modifyTVar' (receiptsRecorded receipts) (Map.delete (attachment, slot))

-- | A batch recording this revision into a registered offscreen target, noted by the owner action that recorded it,
-- with the reading of its ticket. It is promoted once the batch is complete.
noteOffscreenBatch ∷ DrawReceipts → BatchTicket → WorldTag → TargetMetrics → STM ()
noteOffscreenBatch receipts ticket tag metrics = do
  live ← Set.member (tagView tag) <$> readTVar (receiptsLive receipts)
  when live (modifyTVar' (receiptsOffscreen receipts) (|> (ticket, tag, metrics)))

-- | Promote the offscreen batches noted so far, in their order: a complete batch advances its view's receipt, a
-- discarded or lost one is dropped, and the first one still pending holds back the later ones of its view. Answers
-- whether any was settled.
sweepOffscreen ∷ DrawReceipts → STM Bool
sweepOffscreen receipts = do
  pending ← readTVar (receiptsOffscreen receipts)
  kept ← go Set.empty Seq.empty (foldr (:) [] pending)
  let changed = Seq.length kept /= Seq.length pending
  when changed (writeTVar (receiptsOffscreen receipts) kept)
  pure changed
  where
    go _ kept [] = pure kept
    go held kept (entry@(ticket, tag, metrics) : rest)
      | Set.member (tagView tag) held = go held (kept |> entry) rest
      | otherwise =
          readTicket ticket >>= \case
            TicketPending → go (Set.insert (tagView tag) held) (kept |> entry) rest
            TicketComplete → noteSubmitted receipts tag metrics >> go held kept rest
            _ → go held kept rest

-- | Whether 'sweepOffscreen' would note or drop any batch now, read-only: a view's first pending batch whose ticket has
-- settled. For a reader that waits outside any commit.
offscreenSweepDue ∷ DrawReceipts → STM Bool
offscreenSweepDue receipts = readTVar (receiptsOffscreen receipts) >>= go Set.empty . foldr (:) []
  where
    go _ [] = pure False
    go held ((ticket, tag, _) : rest)
      | Set.member (tagView tag) held = go held rest
      | otherwise =
          readTicket ticket >>= \case
            TicketPending → go (Set.insert (tagView tag) held) rest
            _ → pure True

-- | A batch that drew this revision is known to have been submitted (a host stepped by a test says so directly).
noteSubmitted ∷ DrawReceipts → WorldTag → TargetMetrics → STM ()
noteSubmitted receipts tag metrics = do
  live ← Set.member (tagView tag) <$> readTVar (receiptsLive receipts)
  when live $ do
    drawn ← readTVar (receiptsDrawn receipts)
    let count = maybe 1 ((+ 1) . drawnCount) (Map.lookup (tagView tag) drawn)
    writeTVar (receiptsDrawn receipts) (Map.insert (tagView tag) (Drawn tag metrics count) drawn)

-- | The host's frame observer for receipts: a frame whose presentation was enqueued draws what was recorded for its
-- attachment and slot; an abandoned frame drew nothing; every event promotes the offscreen batches that completed.
-- Every frame event is counted, and so is every presentation's enqueue.
receiptObserver ∷ DrawReceipts → FrameObserver
receiptObserver receipts event = atomically $ do
  presented ← case event of
    FramePresented attachment slot _ _ → do
      recorded ← readTVar (receiptsRecorded receipts)
      for_ (Map.lookup (attachment, slot) recorded) $ \(tag, metrics) → do
        writeTVar (receiptsRecorded receipts) (Map.delete (attachment, slot) recorded)
        noteSubmitted receipts tag metrics
      pure True
    FrameAbandoned attachment slot _ → False <$ modifyTVar' (receiptsRecorded receipts) (Map.delete (attachment, slot))
    _ → pure False
  _ ← sweepOffscreen receipts
  modifyTVar' (receiptsEvents receipts) (\(events, presentations) → (events + 1, if presented then presentations + 1 else presentations))

-- | How many frame events the observer has seen, and how many of them were a presentation's enqueue: each moves with
-- every such event, and only with them.
receiptsFrames ∷ DrawReceipts → STM (Natural, Natural)
receiptsFrames receipts = readTVar (receiptsEvents receipts)

-- | A view watches this window attachment from now on: its metrics are not evicted.
watchFrameMetrics ∷ DrawReceipts → AttachmentId → STM ()
watchFrameMetrics receipts attachment = modifyTVar' (receiptsWatched receipts) (Map.insertWith (+) attachment 1)

-- | A view stops watching it.
unwatchFrameMetrics ∷ DrawReceipts → AttachmentId → STM ()
unwatchFrameMetrics receipts attachment = modifyTVar' (receiptsWatched receipts) (Map.update (\n → if n <= 1 then Nothing else Just (n - 1)) attachment)

-- | A frame of this window attachment is recorded with these metrics: written only when they change. Beyond
-- 'metricsKept' unwatched attachments, the least recently drawn one's are forgotten.
noteFrameMetrics ∷ DrawReceipts → AttachmentId → TargetMetrics → STM ()
noteFrameMetrics receipts attachment metrics = do
  held ← readTVar (receiptsMetrics receipts)
  case Map.lookup attachment held of
    Just (same, _) | same == metrics → pure ()
    _ → do
      now ← stateTVar (receiptsClock receipts) (\t → (t, t + 1))
      watched ← readTVar (receiptsWatched receipts)
      let updated = Map.insert attachment (metrics, now) held
          unwatched = [(at, a) | (a, (_, at)) ← Map.toList updated, Map.notMember a watched]
          evicted
            | length unwatched > metricsKept = maybe updated (\(_, a) → Map.delete a updated) (minimumMaybe unwatched)
            | otherwise = updated
      writeTVar (receiptsMetrics receipts) evicted
  where
    minimumMaybe [] = Nothing
    minimumMaybe xs = Just (minimum xs)

-- | The metrics of the attachment's latest recorded frame, while they are kept.
latestFrameMetrics ∷ DrawReceipts → AttachmentId → STM (Maybe TargetMetrics)
latestFrameMetrics receipts attachment = fmap fst . Map.lookup attachment <$> readTVar (receiptsMetrics receipts)
