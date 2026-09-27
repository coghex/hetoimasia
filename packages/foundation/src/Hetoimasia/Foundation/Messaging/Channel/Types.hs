{-# LANGUAGE RoleAnnotations #-}

-- | The channel representation, its phases, the three endpoints with their
-- role annotations, the capacity error, and the result and statistics types
-- the channel operations return.
--
-- __Ownership.__ The foundation owns these types. This hidden module of the
-- foundation's main library holds their representations and constructors;
-- "Hetoimasia.Foundation.Messaging.Channel" owns every channel operation and is
-- the only channel module a client imports. It re-exports 'ChannelControl',
-- 'Sender' and 'Receiver' without their constructors, so the endpoints stay
-- abstract outside the package, and never exports 'Channel' or 'Phase'.
--
-- __Dependencies.__ This module imports "Hetoimasia.Foundation.Messaging.Payload"
-- for the 'Prepared' entries a channel holds, and nothing from the snapshot
-- family, logging, or failures.
--
-- __State.__ The module defines the channel's state but creates and changes
-- none; the state table in "Hetoimasia.Foundation.Messaging.Channel" names its
-- owner, readers and writers.
module Hetoimasia.Foundation.Messaging.Channel.Types
  ( -- * Representation
    Channel (..)
  , Phase (..)

    -- * Endpoints
  , ChannelControl (..)
  , Sender (..)
  , Receiver (..)

    -- * Construction
  , ChannelCapacityRejected (..)

    -- * Results
  , SendResult (..)
  , Admission (..)
  , Termination (..)
  , Receipt (..)
  , Delivery (..)

    -- * Statistics
  , ChannelStatistics (..)
  ) where

import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Numeric.Natural (Natural)

-- | The shared representation behind all three endpoints.
data Channel a = Channel
  { channelCapacity ∷ !Int
  , channelFront ∷ !(TVar [Prepared a])
    -- ^ The oldest entries, in receive order.
  , channelBack ∷ !(TVar [Prepared a])
    -- ^ The newest entries, most recent first.
  , channelPhase ∷ !(TVar Phase)
  , channelDepth ∷ !(TVar Int)
  , channelHighWater ∷ !(TVar Int)
  , channelAccepted ∷ !(TVar Natural)
  , channelDequeued ∷ !(TVar Natural)
  , channelDiscarded ∷ !(TVar Natural)
  }

data Phase = Open | ClosedPhase | AbortedPhase
  deriving (Eq)

-- | The owner-control endpoint: it closes and aborts the channel, reads its
-- statistics, and hands out the send and receive endpoints.
--
-- The role is nominal, as for 'Prepared', so no endpoint can be coerced to a
-- different payload type.
type role ChannelControl nominal

newtype ChannelControl a = ChannelControl (Channel a)

-- | An endpoint that can only send.
type role Sender nominal

newtype Sender a = Sender (Channel a)

-- | An endpoint that can only receive.
type role Receiver nominal

newtype Receiver a = Receiver (Channel a)

-- | Why 'Hetoimasia.Foundation.Messaging.Channel.newChannel' refused a
-- capacity.
data ChannelCapacityRejected
  = CapacityNotPositive !Integer
  | CapacityAboveMaximum !Integer
  deriving (Eq, Show)

instance Exception ChannelCapacityRejected

-- Sending ----------------------------------------------------------------------

-- | What an immediate send did.
data SendResult
  = Accepted
    -- ^ The payload was admitted.
  | Full
    -- ^ The channel is open and holds capacity entries. Nothing changed.
  | Closed
    -- ^ Admission has ended, by close or abort. Nothing changed.
  deriving (Eq, Show)

-- | What a waiting send did.
data Admission
  = Admitted
    -- ^ The payload was admitted.
  | AdmissionClosed
    -- ^ Admission ended, by close or abort, before capacity was available.
    -- Nothing changed.
  deriving (Eq, Show)

-- Receiving --------------------------------------------------------------------

-- | Why a channel will deliver nothing more.
data Termination
  = Drained
    -- ^ It was closed, and every accepted entry has been received.
  | Aborted
    -- ^ It was aborted.
  deriving (Eq, Show)

-- | What an immediate receive found.
data Receipt a
  = Received (Prepared a)
  | Empty
    -- ^ The channel is open and holds no entries.
  | Terminated !Termination

-- | What a waiting receive found.
data Delivery a
  = Delivered (Prepared a)
  | Ended !Termination

-- Statistics -------------------------------------------------------------------

-- | One coherent observation of a channel's counters. It holds no payload.
data ChannelStatistics = ChannelStatistics
  { statisticsCapacity ∷ !Natural
  , statisticsDepth ∷ !Natural
    -- ^ Entries accepted and neither received nor discarded.
  , statisticsHighWater ∷ !Natural
    -- ^ The largest depth the channel has held.
  , statisticsAccepted ∷ !Natural
    -- ^ Payloads admitted by a committed send.
  , statisticsDequeued ∷ !Natural
    -- ^ Entries returned by a committed receive.
  , statisticsDiscarded ∷ !Natural
    -- ^ Entries dropped by abort.
  }
  deriving (Eq, Show)
