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
-- * a registered offscreen target: the successful submission of the batch that recorded it ('noteSubmitted').
--
-- Adoption alone, a recording, a refused or abandoned frame and a frame of an M1 scene leave the receipt as it
-- was. A receipt is kept for each view incarnation until the view forgets it ('forgetReceipt', at its close).
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
-- | The listener    | the scene       | the terrain views' scope              | the observer        | that scope's     |
-- |                 | session         |                                       |                     |                  |
-- +-----------------+-----------------+---------------------------------------+---------------------+------------------+
--
-- A recorded frame lives only between two events the host reports for the same frame slot, so at most one is kept
-- per attachment and slot; a recording the host never reports again is replaced by the slot's next recording. The
-- observer runs one transaction per event and neither waits nor raises.
module Hetoimasia.LuaEngine.Graphics.Scene.Receipts
  ( DrawReceipts
  , newDrawReceipts
  , Drawn (..)
  , readReceipt
  , forgetReceipt
  , noteRecorded
  , noteUnrecorded
  , noteSubmitted
  , receiptObserver
  , receiptsListen
  , noteFrameMetrics
  , latestFrameMetrics
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.GPU.Vulkan.GLFW (FrameEvent (..), FrameObserver)
import Hetoimasia.GPU.Model.Identity (FrameSlotId)
import Hetoimasia.Runtime.GLFW (AttachmentId)
import Hetoimasia.LuaEngine.Graphics.Scene.World (WorldTag (..))
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)
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
  , receiptsDrawn ∷ !(TVar (Map Word64 Drawn))
  , receiptsListener ∷ !(TVar (Bool → STM ()))
  , receiptsMetrics ∷ !(TVar (Map AttachmentId TargetMetrics))
    -- ^ The metrics of each window attachment's latest recorded frame: what a view of that window plans for.
  }

newDrawReceipts ∷ IO DrawReceipts
newDrawReceipts = DrawReceipts <$> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO (const (pure ())) <*> newTVarIO Map.empty

-- | The view incarnation's latest receipt, if it has drawn.
readReceipt ∷ DrawReceipts → Word64 → STM (Maybe Drawn)
readReceipt receipts view = Map.lookup view <$> readTVar (receiptsDrawn receipts)

-- | Forget a view incarnation's receipt (its close).
forgetReceipt ∷ DrawReceipts → Word64 → STM ()
forgetReceipt receipts view = modifyTVar' (receiptsDrawn receipts) (Map.delete view)

-- | A frame of a world scene was recorded for this attachment and slot: what it will have drawn if its presentation
-- is enqueued. Called by the renderer on the graphics owner's thread.
noteRecorded ∷ DrawReceipts → AttachmentId → FrameSlotId → WorldTag → TargetMetrics → STM ()
noteRecorded receipts attachment slot tag metrics =
  modifyTVar' (receiptsRecorded receipts) (Map.insert (attachment, slot) (tag, metrics))

-- | A frame of anything but a world scene was recorded for this attachment and slot: it draws nothing a receipt
-- names.
noteUnrecorded ∷ DrawReceipts → AttachmentId → FrameSlotId → STM ()
noteUnrecorded receipts attachment slot = modifyTVar' (receiptsRecorded receipts) (Map.delete (attachment, slot))

-- | A batch recording this revision into a registered offscreen target was submitted.
noteSubmitted ∷ DrawReceipts → WorldTag → TargetMetrics → STM ()
noteSubmitted = advance

advance ∷ DrawReceipts → WorldTag → TargetMetrics → STM ()
advance receipts tag metrics = do
  drawn ← readTVar (receiptsDrawn receipts)
  let count = maybe 1 ((+ 1) . drawnCount) (Map.lookup (tagView tag) drawn)
  writeTVar (receiptsDrawn receipts) (Map.insert (tagView tag) (Drawn tag metrics count) drawn)

-- | The host's frame observer for receipts: a frame whose presentation was enqueued draws what was recorded for its
-- attachment and slot; an abandoned frame drew nothing. Every frame event also runs the listener, told whether it was
-- a presentation's enqueue.
receiptObserver ∷ DrawReceipts → FrameObserver
receiptObserver receipts event = atomically $ case event of
  FramePresented attachment slot _ _ → do
    recorded ← readTVar (receiptsRecorded receipts)
    for_ (Map.lookup (attachment, slot) recorded) $ \(tag, metrics) → do
      writeTVar (receiptsRecorded receipts) (Map.delete (attachment, slot) recorded)
      advance receipts tag metrics
    listen True
  FrameAbandoned attachment slot _ → modifyTVar' (receiptsRecorded receipts) (Map.delete (attachment, slot)) >> listen False
  _ → listen False
  where
    listen presented = readTVar (receiptsListener receipts) >>= \run → run presented

-- | Install the transaction every frame event runs, given whether the event was a presentation's enqueue
-- ('const (pure ())' clears it). It must not wait or raise.
receiptsListen ∷ DrawReceipts → (Bool → STM ()) → STM ()
receiptsListen receipts = writeTVar (receiptsListener receipts)

-- | A frame of this window attachment is recorded with these metrics. Written only when they change.
noteFrameMetrics ∷ DrawReceipts → AttachmentId → TargetMetrics → STM ()
noteFrameMetrics receipts attachment metrics = do
  held ← readTVar (receiptsMetrics receipts)
  case Map.lookup attachment held of
    Just same | same == metrics → pure ()
    _ → writeTVar (receiptsMetrics receipts) (Map.insert attachment metrics held)

-- | The metrics of the attachment's latest recorded frame, once it has had one.
latestFrameMetrics ∷ DrawReceipts → AttachmentId → STM (Maybe TargetMetrics)
latestFrameMetrics receipts attachment = Map.lookup attachment <$> readTVar (receiptsMetrics receipts)
