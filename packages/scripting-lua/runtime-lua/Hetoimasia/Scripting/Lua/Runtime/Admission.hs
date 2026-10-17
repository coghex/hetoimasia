-- | The admission state of one owner: the bounded queue, the reservations, and
-- the single place each call's settlement is written.
--
-- Everything here is one STM transaction at a time and none of it waits except
-- where its name says it retries. That is what makes admission a three-way
-- answer rather than a wait, and what makes each of the invariants below a
-- property of one transaction rather than of an interleaving:
--
-- * A call is accepted, a reservation taken and the call enqueued together, or
--   none of them. A full or closed answer changes nothing.
-- * A slot's settlement is written once. A later write, from any path, is
--   ignored, so a late result can never overwrite a settlement.
-- * A reservation is given back once, whoever observes or abandons the result
--   first and however often it is observed again.
-- * The call the owner's thread takes is recorded as in flight in the same
--   transaction that dequeues it, so a call is always queued, in flight or
--   settled, and an exit that discards what is unsettled misses none.
module Hetoimasia.Scripting.Lua.Runtime.Admission
  ( -- * Admission
    newControl
  , admit
  , openAdmission
  , admitting
    -- * The owner's side
  , takeNext
  , finishCall
  , shutAndDiscard
    -- * The caller's side
  , newSlot
  , observeSlot
  , forgetSlot
  ) where

import Control.Concurrent.STM
  ( STM
  , modifyTVar'
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Monad (forM_, when)
import Hetoimasia.Foundation.Messaging.Channel
  ( Receipt (Empty, Received, Terminated)
  , SendResult (Accepted)
  , channelReceiver
  , channelSender
  , closeChannel
  , newChannel
  , receive
  , send
  )
import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import qualified Hetoimasia.Foundation.Messaging.Channel as Channel
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Runtime.Types
import Hetoimasia.Scripting.Lua.Value (ValueLimits)

-- | The control of an owner that is constructed and not yet admitting.
--
-- Allocates only what is bounded by the configuration: the queue, which holds
-- nothing until a call is accepted, and the counters.
newControl ∷ OwnerId → Text → ValueLimits → CallBounds → STM Bool → IO Control
newControl owner label limits bounds stopping =
  Control owner label limits bounds
    <$> newTVarIO Opening
    <*> pure stopping
    <*> newChannel (toInteger (boundQueuedCalls bounds))
    <*> newTVarIO 0
    <*> newTVarIO Nothing
    <*> newTVarIO Nothing

-- | Whether the owner is admitting calls: open, and not asked to stop.
admitting ∷ Control → STM Bool
admitting control = do
  phase ← readTVar (controlPhase control)
  stopping ← controlStopping control
  pure (phase == Admitting && not stopping)

-- | Begin admitting, once the owner is ready. An owner that has already ended
-- stays ended.
openAdmission ∷ Control → STM ()
openAdmission control = do
  phase ← readTVar (controlPhase control)
  when (phase == Opening) (writeTVar (controlPhase control) Admitting)

-- | Accept a prepared call, or say why not.
--
-- Closed takes precedence over full, and an owner that has been asked to stop is
-- closed from that moment, whether or not its thread has got as far as acting on
-- the request: a stuck call does not keep admission open. Full is either bound: the queue is at its
-- capacity, or every result reservation is held. Accepting takes the
-- reservation and enqueues the call in the same transaction.
admit ∷ Control → Prepared QueuedCall → STM SendResult
admit control call = do
  open ← admitting control
  if not open
    then pure Channel.Closed
    else do
      outstanding ← readTVar (controlOutstanding control)
      if outstanding >= boundResults (controlBounds control)
        then pure Channel.Full
        else do
          sent ← send (channelSender (controlChannel control)) call
          when (sent == Accepted) (writeTVar (controlOutstanding control) (outstanding + 1))
          pure sent

-- | Take the next queued call, marking it in flight in the same transaction.
-- Retries while the queue is empty.
takeNext ∷ Control → STM QueuedCall
takeNext control =
  receive (channelReceiver (controlChannel control)) >>= \case
    Received prepared → do
      let call = preparedValue prepared
      writeTVar (controlInflight control) (Just call)
      pure call
    Empty → retry
    Terminated _ → retry

-- | Settle the call the owner's thread had in flight and clear it, together.
finishCall ∷ Control → QueuedCall → Outcome → STM ()
finishCall control call outcome = do
  settle control (queuedSlot call) outcome
  writeTVar (controlInflight control) Nothing

-- | End admission, then settle everything that has not settled as discarded,
-- and record the exit.
--
-- Admission closes first and in the same transaction, so no call can be
-- accepted after the discard has looked at the queue. The in-flight call, if
-- there is one, is discarded as started and every queued call as not started,
-- each with the way the owner exited. The exit record is written once: a later
-- call, after anything else already ended the owner, discards what it still
-- finds and adds it to the counts, and changes nothing it already said.
shutAndDiscard ∷ Control → ExitKind → STM ()
shutAndDiscard control kind = do
  writeTVar (controlPhase control) Shut
  closeChannel (controlChannel control)
  inflight ← readTVar (controlInflight control)
  started ← case inflight of
    Just call → do
      settle control (queuedSlot call) (CallDiscarded (Discard kind Started))
      writeTVar (controlInflight control) Nothing
      pure 1
    Nothing → pure 0
  queued ← drain
  forM_ queued $ \call → settle control (queuedSlot call) (CallDiscarded (Discard kind NotStarted))
  readTVar (controlExit control) >>= \case
    Nothing →
      writeTVar (controlExit control) . Just $
        ExitRecord (controlOwner control) (controlLabel control) kind (length queued) started
    Just prior →
      writeTVar (controlExit control) . Just $
        prior {exitNotStarted = exitNotStarted prior + length queued, exitStarted = exitStarted prior + started}
  where
    drain =
      receive (channelReceiver (controlChannel control)) >>= \case
        Received prepared → (preparedValue prepared :) <$> drain
        _ → pure []

-- | A slot with nothing settled in it and no interest withdrawn.
newSlot ∷ IO Slot
newSlot = Slot <$> newTVarIO Nothing <*> newTVarIO False <*> newTVarIO False

-- | Write a slot's settlement, unless it already has one. A call a caller has
-- already abandoned gives its reservation back as it settles.
settle ∷ Control → Slot → Outcome → STM ()
settle control slot outcome =
  readTVar (slotSettlement slot) >>= \case
    Just _ → pure ()
    Nothing → do
      writeTVar (slotSettlement slot) (Just (Settlement (controlOwner control) (controlLabel control) outcome))
      forgotten ← readTVar (slotForgotten slot)
      when forgotten (release control slot)

-- | Give a slot's reservation back, once.
release ∷ Control → Slot → STM ()
release control slot = do
  released ← readTVar (slotReleased slot)
  when (not released) $ do
    writeTVar (slotReleased slot) True
    modifyTVar' (controlOutstanding control) (subtract 1)

-- | Read a slot's settlement without waiting. Reading a settlement is
-- observing it: the first read that finds one gives the reservation back, and
-- every later read answers the same settlement and gives nothing back.
observeSlot ∷ Control → Slot → STM (Maybe Settlement)
observeSlot control slot =
  readTVar (slotSettlement slot) >>= \case
    Nothing → pure Nothing
    Just settlement → Just settlement <$ release control slot

-- | Withdraw interest in a call's result. A settled result gives its
-- reservation back now, an unsettled one when it settles. The settlement is
-- still readable from the caller's own ticket afterwards.
forgetSlot ∷ Control → Slot → STM ()
forgetSlot control slot = do
  writeTVar (slotForgotten slot) True
  readTVar (slotSettlement slot) >>= \case
    Just _ → release control slot
    Nothing → pure ()
