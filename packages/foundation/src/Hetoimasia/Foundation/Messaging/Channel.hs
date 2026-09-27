-- | Bounded FIFO channels of prepared payloads, with a terminal state and
-- atomic counters.
--
-- A channel is created in 'IO' by its owner with 'newChannel', which returns
-- the owner-control endpoint, 'ChannelControl'. The owner hands out the other
-- two endpoints: a 'Sender', which can only send, and a 'Receiver', which can
-- only receive. Neither can close or abort the channel, and neither can reach
-- the other's operations. Every endpoint is abstract and every operation is an
-- ordinary function; no queue, 'TVar', or other private state escapes.
--
-- __Module structure.__ This is the only channel module a client imports.
-- Inside the foundation, the channel representation, its phases, the endpoints
-- with their nominal roles, 'ChannelCapacityRejected', and the result and
-- statistics types are defined in "Hetoimasia.Foundation.Messaging.Channel.Types",
-- and 'messagingComponent' in "Hetoimasia.Foundation.Messaging.Component"; both
-- are hidden modules of the main library, and this module re-exports what
-- clients may use from them without the endpoints' constructors. This module
-- itself defines every channel operation.
--
-- __Capacity and admission.__ The owner chooses the capacity. A capacity that
-- is not positive, or is above 'maximumCapacity', raises a typed
-- 'ChannelCapacityRejected' failure with engine origin before any channel
-- exists: there is no clamping, no zero-capacity rendezvous, and no engine-wide
-- default. 'send' never waits. It reports 'Accepted', 'Full' when the channel
-- holds capacity entries, or 'Closed' once admission has ended; 'Closed' takes
-- precedence over 'Full'. A 'Full' or 'Closed' result changes nothing, so the
-- caller still has its payload. 'awaitSend' is the separate operation that waits
-- for capacity, and only while the channel is open.
--
-- __Payloads.__ Every send takes a 'Prepared' payload, and a receive returns the
-- same handle, so a payload is forwarded to another channel without 'NFData' or
-- evaluation.
--
-- __Order.__ Entries are received in the order their admissions committed. No
-- wall-clock order, fairness among producers, batching, or coalescing is
-- promised.
--
-- __Close and abort.__ 'closeChannel' ends admission and keeps every accepted
-- entry for receivers to drain in order; once the backlog is empty a receive
-- reports 'Drained'. 'abortChannel' ends admission and drops every queued
-- entry, returning how many it discarded in that call; a receive then reports
-- 'Aborted'. Both are idempotent. Abort strengthens an earlier close, a later
-- close never weakens an abort, and a channel never reopens. Abort cannot
-- recall an entry that was already received. Senders see only 'Closed' in
-- either case: a sender cannot tell why a channel stopped.
--
-- Close and abort never execute 'retry' and never wait for another
-- participant, so both are safe inside a controlled release. Abort reads its
-- discard count from the depth counter; it neither traverses nor forces the
-- backlog it drops.
--
-- __Where waiting is safe.__ 'awaitSend' and 'awaitReceive' retry only while
-- the channel is open and full, or open and empty, and return once close or
-- abort ends that. Every operation is an 'STM' action, so a wait composes with
-- other transactions: with @awaitSupervised@ from the runtime package's
-- @Hetoimasia.Runtime.Supervision@ on the application thread, and with a
-- worker's 'Hetoimasia.Foundation.Worker.awaitStopRequest' through
-- 'Control.Monad.STM.orElse'. A wait that is not composed with one of those
-- blocks until the channel changes. Never wait inside a release; close and abort
-- are the operations a release may use.
--
-- __Consumers.__ Any number of threads may hold a 'Sender' or a 'Receiver'.
-- One logical consumer per channel is an ownership convention the owner keeps,
-- not something the types enforce.
--
-- __Statistics.__ 'channelStatistics' reads the capacity, depth, high-water
-- depth, and cumulative accepted, dequeued, and discarded counts in one
-- transaction. The counts never wrap, and every committed state satisfies
-- @accepted = dequeued + discarded + depth@. High-water never decreases and
-- never exceeds the capacity. A 'Full' or 'Closed' result, or a transaction that
-- rolled back, counts nothing.
--
-- __Transaction hygiene.__ No operation evaluates a payload, reads a clock,
-- logs, invokes a callback or destructor, or uses 'GHC.Conc.unsafeIOToSTM'. No
-- operation raises a typed failure inside 'STM'.
--
-- __State.__ One channel owns all of it; nothing is shared between channels.
--
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | State               | Readers and writers                            | Thread      | Lifetime and reset                        |
-- +=====================+================================================+=============+===========================================+
-- | Channel entries     | Sends append; receives remove from the front;  | Any holder  | Until received or discarded by abort;     |
-- |                     | abort drops all                                | of an       | the channel lives while referenced        |
-- |                     |                                                | endpoint    |                                           |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | Terminal flag       | Close and abort write; every send and receive  | Any holder  | Open until close or abort; never reopens  |
-- |                     | reads                                          |             |                                           |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
-- | Counters            | Accepting sends, receives, and abort write;    | Any holder  | Cumulative for the channel's life; never  |
-- |                     | 'channelStatistics' reads                      |             | reset                                     |
-- +---------------------+------------------------------------------------+-------------+-------------------------------------------+
--
-- See @docs/messaging.md@ for the same contract in prose.
module Hetoimasia.Foundation.Messaging.Channel
  ( -- * Construction
    ChannelControl
  , newChannel
  , maximumCapacity
  , ChannelCapacityRejected (..)
  , messagingComponent
  , newChannelOperation

    -- * Endpoints
  , Sender
  , channelSender
  , Receiver
  , channelReceiver

    -- * Sending
  , SendResult (..)
  , send
  , Admission (..)
  , awaitSend

    -- * Receiving
  , Receipt (..)
  , receive
  , Delivery (..)
  , awaitReceive
  , Termination (..)

    -- * Owner control
  , closeChannel
  , abortChannel

    -- * Statistics
  , ChannelStatistics (..)
  , channelStatistics
  ) where

import Control.Concurrent.STM (STM, modifyTVar', newTVarIO, readTVar, retry, writeTVar)
import Control.Monad (when)
import Data.Text (pack)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Messaging.Channel.Types
import Hetoimasia.Foundation.Messaging.Component (messagingComponent)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Numeric.Natural (Natural)

-- | The operation a construction failure names as its origin.
newChannelOperation ∷ Operation
newChannelOperation = operation "new-channel"

-- | The largest capacity a channel accepts: the largest depth its counter
-- represents.
maximumCapacity ∷ Integer
maximumCapacity = toInteger (maxBound ∷ Int)

-- | Create an open, empty channel with the given capacity.
--
-- A capacity below one or above 'maximumCapacity' throws
-- 'ChannelCapacityRejected' through 'throwFailure', attributed to the caller,
-- with the capacity as an identifier, and no channel is created. Construction
-- allocates nothing proportional to the capacity.
newChannel ∷ HasCallStack ⇒ Integer → IO (ChannelControl a)
newChannel capacity
  | capacity < 1 = rejected (CapacityNotPositive capacity)
  | capacity > maximumCapacity = rejected (CapacityAboveMaximum capacity)
  | otherwise =
      fmap ChannelControl $
        Channel (fromInteger capacity)
          <$> newTVarIO []
          <*> newTVarIO []
          <*> newTVarIO Open
          <*> newTVarIO 0
          <*> newTVarIO 0
          <*> newTVarIO 0
          <*> newTVarIO 0
          <*> newTVarIO 0
  where
    rejected ∷ HasCallStack ⇒ ChannelCapacityRejected → IO b
    rejected =
      throwFailure messagingComponent newChannelOperation [("capacity", pack (show capacity))]

-- | The channel's send endpoint.
channelSender ∷ ChannelControl a → Sender a
channelSender (ChannelControl channel) = Sender channel

-- | The channel's receive endpoint.
channelReceiver ∷ ChannelControl a → Receiver a
channelReceiver (ChannelControl channel) = Receiver channel

-- Sending ----------------------------------------------------------------------

-- | Send without waiting.
send ∷ Sender a → Prepared a → STM SendResult
send (Sender channel) payload = do
  phase ← readTVar (channelPhase channel)
  if phase /= Open
    then pure Closed
    else do
      depth ← readTVar (channelDepth channel)
      if depth >= channelCapacity channel
        then pure Full
        else Accepted <$ admit channel depth payload

-- | Send, waiting for capacity while the channel is open. Returns
-- 'AdmissionClosed' as soon as admission ends rather than waiting further.
awaitSend ∷ Sender a → Prepared a → STM Admission
awaitSend endpoint payload =
  send endpoint payload >>= \case
    Accepted → pure Admitted
    Full → retry
    Closed → pure AdmissionClosed

-- | Append one payload to an open channel with room for it. The payload is
-- consed on unevaluated.
admit ∷ Channel a → Int → Prepared a → STM ()
admit channel depth payload = do
  modifyTVar' (channelBack channel) (payload :)
  let deeper = depth + 1
  writeTVar (channelDepth channel) deeper
  highWater ← readTVar (channelHighWater channel)
  when (deeper > highWater) (writeTVar (channelHighWater channel) deeper)
  modifyTVar' (channelAccepted channel) (+ 1)

-- Receiving --------------------------------------------------------------------

-- | Receive without waiting.
receive ∷ Receiver a → STM (Receipt a)
receive (Receiver channel) =
  readTVar (channelFront channel) >>= \case
    payload : rest → Received payload <$ taken rest
    [] →
      -- Reversing the back list moves list cells only; no payload is forced.
      reverse <$> readTVar (channelBack channel) >>= \case
        payload : rest → do
          writeTVar (channelBack channel) []
          Received payload <$ taken rest
        [] →
          readTVar (channelPhase channel) >>= \case
            Open → pure Empty
            ClosedPhase → pure (Terminated Drained)
            AbortedPhase → pure (Terminated Aborted)
  where
    taken rest = do
      writeTVar (channelFront channel) rest
      modifyTVar' (channelDepth channel) (subtract 1)
      modifyTVar' (channelDequeued channel) (+ 1)

-- | Receive, waiting while the channel is open and empty.
awaitReceive ∷ Receiver a → STM (Delivery a)
awaitReceive endpoint =
  receive endpoint >>= \case
    Received payload → pure (Delivered payload)
    Empty → retry
    Terminated termination → pure (Ended termination)

-- Owner control ----------------------------------------------------------------

-- | End admission and keep the backlog for draining. Idempotent; it never
-- weakens an abort and never waits.
closeChannel ∷ ChannelControl a → STM ()
closeChannel (ChannelControl channel) = do
  phase ← readTVar (channelPhase channel)
  when (phase == Open) (writeTVar (channelPhase channel) ClosedPhase)

-- | End admission and drop the backlog, returning how many entries this call
-- discarded. Idempotent; it strengthens a close and never waits.
--
-- The count is the depth counter's value. The dropped entries are neither
-- traversed nor forced.
abortChannel ∷ ChannelControl a → STM Natural
abortChannel (ChannelControl channel) = do
  phase ← readTVar (channelPhase channel)
  when (phase /= AbortedPhase) (writeTVar (channelPhase channel) AbortedPhase)
  depth ← readTVar (channelDepth channel)
  if depth == 0
    then pure 0
    else do
      let discarded = fromIntegral depth
      writeTVar (channelFront channel) []
      writeTVar (channelBack channel) []
      writeTVar (channelDepth channel) 0
      modifyTVar' (channelDiscarded channel) (+ discarded)
      pure discarded

-- Statistics -------------------------------------------------------------------

-- | Read every statistic in one transaction.
channelStatistics ∷ ChannelControl a → STM ChannelStatistics
channelStatistics (ChannelControl channel) =
  ChannelStatistics (fromIntegral (channelCapacity channel))
    <$> (fromIntegral <$> readTVar (channelDepth channel))
    <*> (fromIntegral <$> readTVar (channelHighWater channel))
    <*> readTVar (channelAccepted channel)
    <*> readTVar (channelDequeued channel)
    <*> readTVar (channelDiscarded channel)
