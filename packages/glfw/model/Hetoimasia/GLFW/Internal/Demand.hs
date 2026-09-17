-- | Bounded demand slots: how a worker tells the owner it wants a turn.
--
-- A 'DemandSlot' is the owner's side of one coalescing request, and a
-- 'DemandPublisher' is the capability a worker holds to write into it. The
-- window host owns one slot for application demand and one for each live
-- window, and nothing here allocates a slot per worker, per request, or per
-- deadline: a slot's state is one revision and one combined request, whatever
-- the number of publishers or publications.
--
-- = Requests
--
-- A 'DemandRequest' states immediate demand, an absolute deadline, or both.
-- Requests combine as a 'Monoid': immediate demand if any publisher asked for
-- it, and the earliest deadline any publisher requested. So a later publication
-- can never replace an earlier pending deadline with a later one, and a
-- publication carrying no demand ('noDemand') cannot cancel another
-- publisher's request — it changes nothing and is answered 'NoDemandPublished'.
--
-- The deadline is an opaque 'Instant' of
-- "Hetoimasia.Foundation.Time", in the publisher's own clock domain. This
-- module compares deadlines and stores them; it reads no clock and applies no
-- policy, and what a captured request means for the owner's next wait belongs
-- to the owner loop.
--
-- = Publication
--
-- 'publishDemand' records the combined request and advances the slot's
-- revision in one transaction, and only then notifies the owner, through
-- "Hetoimasia.GLFW.Internal.Notify"'s policy. Authoritative state is therefore
-- always recorded before the hint that announces it, exactly as command
-- admission records a command before waking.
--
-- A cancellation delivered before that transaction commits publishes nothing. A
-- cancellation delivered after it commits withdraws nothing: the request stays
-- pending and is notified, and the notification obligation is held
-- uninterruptibly from the commit onward, so no asynchronous exception can
-- separate the two. As with a command's ticket, a publisher cancelled at the
-- instant of the commit may not learn its own answer; the request is still
-- pending, and the owner's finite idle wait is the bounded fallback that serves
-- it if the notification never happened.
--
-- A closed slot rejects publication with 'DemandSlotClosed', makes no native
-- call, and can never be reopened, so a retained publisher is safe after its
-- window ended or its host quiesced and can never resurrect either.
--
-- = Capture
--
-- 'captureDemand' takes the pending request with its revision and clears
-- exactly what it took, in one transaction. A publication that commits after
-- that capture carries a newer revision and stays pending for the next one, so
-- no acknowledgement of an older revision can erase a newer request, and
-- repeated publications between two captures coalesce into the one request the
-- second capture takes. Capturing is the acknowledgement: there is no separate
-- one to go stale.
--
-- A slot holds a coalesced request, never a schedule. An ongoing periodic
-- schedule is the owner's own state, so an old request cannot become permanent
-- work.
--
-- = State
--
-- +---------------------+-------------+------------------------------+---------------+--------------------+--------------------------+
-- | State               | Owner       | Readers and writers          | Thread        | Lifetime           | Reset or disposal        |
-- +=====================+=============+==============================+===============+====================+==========================+
-- | Pending request and | Its slot's  | Publishers combine into it;  | Publish: any; | The slot           | Cleared by each capture; |
-- | revision            | holder      | the owner captures and       | capture and   |                    | frozen once closed       |
-- |                     |             | clears; closure ends it      | close: owner  |                    |                          |
-- +---------------------+-------------+------------------------------+---------------+--------------------+--------------------------+
--
-- None of this is application state, and none of it holds a native handle.
module Hetoimasia.GLFW.Internal.Demand
  ( -- * Requests
    DemandRequest
  , noDemand
  , immediateDemand
  , deadlineDemand
  , demandIsImmediate
  , demandDeadline
  , demandRequested

    -- * Slots
  , DemandSlot
  , newDemandSlot
  , closeDemandSlot
  , DemandStatus (..)
  , demandStatus
  , CapturedDemand (..)
  , captureDemand

    -- * Publishers
  , DemandPublisher
  , demandPublisher
  , PublishResult (..)
  , publishDemand

    -- * Private publication protocol
  , DemandHooks (..)
  , noDemandHooks
  , publishDemandWith
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (mask_, uninterruptibleMask_)
import Control.Monad (void)
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GLFW.Internal.Notify (Notifier, notifyOwner)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Requests

-- | What a publisher wants of the owner: an immediate turn, a turn by an
-- absolute deadline, or both. Its representation is private, so a request is
-- only ever built and combined by this module's operations.
data DemandRequest = DemandRequest
  { requestImmediate ∷ !Bool
  , requestDeadline ∷ !(Maybe Instant)
  }
  deriving (Eq, Show)

-- | Combine: immediate if either asks for it, and the earlier deadline.
instance Semigroup DemandRequest where
  left <> right =
    DemandRequest
      { requestImmediate = requestImmediate left || requestImmediate right
      , requestDeadline = case (requestDeadline left, requestDeadline right) of
          (Nothing, later) → later
          (earlier, Nothing) → earlier
          (Just earlier, Just later) → Just (min earlier later)
      }

instance Monoid DemandRequest where
  mempty = noDemand

-- | No demand at all: the unit of combination, which changes nothing wherever
-- it is published.
noDemand ∷ DemandRequest
noDemand = DemandRequest False Nothing

-- | Demand a turn now.
immediateDemand ∷ DemandRequest
immediateDemand = DemandRequest True Nothing

-- | Demand a turn by an absolute instant, in the publisher's clock domain.
deadlineDemand ∷ Instant → DemandRequest
deadlineDemand deadline = DemandRequest False (Just deadline)

-- | Whether a turn was demanded immediately.
demandIsImmediate ∷ DemandRequest → Bool
demandIsImmediate = requestImmediate

-- | The earliest deadline demanded, if any.
demandDeadline ∷ DemandRequest → Maybe Instant
demandDeadline = requestDeadline

-- | Whether the request demands anything at all.
demandRequested ∷ DemandRequest → Bool
demandRequested request = requestImmediate request || maybe False (const True) (requestDeadline request)

-- ---------------------------------------------------------------------------
-- Slots

-- | One coalescing demand slot. Its representation is private, and it holds no
-- native handle.
newtype DemandSlot = DemandSlot (TVar SlotState)
  deriving (Eq)

data SlotState
  = SlotOpen !Natural !DemandRequest
  | SlotClosed !Natural
  deriving (Eq)

-- | An open, empty slot whose first accepted publication is revision one.
newDemandSlot ∷ IO DemandSlot
newDemandSlot = DemandSlot <$> newTVarIO (SlotOpen 0 noDemand)

-- | End publication in the calling transaction, dropping whatever was pending.
-- Finite, never retries, idempotent, and never reopened.
closeDemandSlot ∷ DemandSlot → STM ()
closeDemandSlot (DemandSlot cell) =
  readTVar cell >>= \case
    SlotOpen revision _ → writeTVar cell (SlotClosed revision)
    SlotClosed _ → pure ()

-- | One coherent observation of a slot.
data DemandStatus = DemandStatus
  { statusOpen ∷ !Bool
  , statusRevision ∷ !Natural
    -- ^ The revision of the latest accepted publication; zero before the first.
  , statusPending ∷ !(Maybe DemandRequest)
    -- ^ The request a capture would take, if one is pending.
  }
  deriving (Eq, Show)

-- | Read a slot's state in one transaction, without capturing anything.
demandStatus ∷ DemandSlot → STM DemandStatus
demandStatus (DemandSlot cell) =
  readTVar cell >>= \case
    SlotOpen revision request →
      pure (DemandStatus True revision (if demandRequested request then Just request else Nothing))
    SlotClosed revision → pure (DemandStatus False revision Nothing)

-- | What a capture took: the request, and the revision of the newest
-- publication it includes.
data CapturedDemand = CapturedDemand
  { capturedRevision ∷ !Natural
  , capturedRequest ∷ !DemandRequest
  }
  deriving (Eq, Show)

-- | Take the pending request and clear exactly what was taken, in one
-- transaction. A closed slot, and an open slot with nothing pending, answer
-- 'Nothing'. Never retries.
captureDemand ∷ DemandSlot → STM (Maybe CapturedDemand)
captureDemand (DemandSlot cell) =
  readTVar cell >>= \case
    SlotOpen revision request
      | demandRequested request → do
          writeTVar cell (SlotOpen revision noDemand)
          pure (Just (CapturedDemand revision request))
    _ → pure Nothing

-- ---------------------------------------------------------------------------
-- Publishers

-- | The capability to publish into one slot: it can only publish. Its
-- representation is private, and it carries no native handle and no capture,
-- closure, or window authority.
data DemandPublisher = DemandPublisher
  { publisherSlot ∷ !DemandSlot
  , publisherNotifier ∷ !Notifier
  }

-- | The publisher for a slot, over the session's notifier.
demandPublisher ∷ DemandSlot → Notifier → DemandPublisher
demandPublisher = DemandPublisher

-- | What a publication did.
data PublishResult
  = DemandPublished !Natural
    -- ^ Combined into the slot as this revision, and the owner notified.
  | NoDemandPublished
    -- ^ The request demanded nothing. The slot is unchanged and nothing was
    -- notified.
  | DemandSlotClosed
    -- ^ Publication has ended. Nothing was recorded and no native call was
    -- made.
  deriving (Eq, Show)

-- | Where the private publication examples interrupt a publisher.
data DemandHooks = DemandHooks
  { beforePublication ∷ IO ()
    -- ^ Before the publishing transaction.
  , afterPublication ∷ IO ()
    -- ^ After it committed, inside the protection that owes the notification.
  }

noDemandHooks ∷ DemandHooks
noDemandHooks = DemandHooks (pure ()) (pure ())

-- | Publish demand: combine it into the slot, advance the revision, and then
-- notify the owner.
--
-- Closure takes precedence over everything, and a request demanding nothing
-- changes nothing. An accepted publication owes its notification from the
-- commit onward, whatever is delivered to the publishing thread.
publishDemand ∷ DemandPublisher → DemandRequest → IO PublishResult
publishDemand = publishDemandWith noDemandHooks

-- | 'publishDemand', interrupted where the hooks say.
publishDemandWith ∷ DemandHooks → DemandPublisher → DemandRequest → IO PublishResult
publishDemandWith hooks publisher request = do
  beforePublication hooks
  mask_ $ do
    published ← atomically (record (publisherSlot publisher))
    case published of
      DemandPublished _ → uninterruptibleMask_ (afterPublication hooks >> void (notifyOwner (publisherNotifier publisher)))
      _ → pure ()
    pure published
  where
    record (DemandSlot cell) =
      readTVar cell >>= \case
        SlotClosed _ → pure DemandSlotClosed
        SlotOpen revision pending
          | not (demandRequested request) → pure NoDemandPublished
          | otherwise → do
              let advanced = revision + 1
              writeTVar cell (SlotOpen advanced (pending <> request))
              pure (DemandPublished advanced)
