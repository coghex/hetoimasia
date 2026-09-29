-- | Room held on the owner's bounded lifetime port before a main-thread
-- handover or release spends it.
--
-- Main thread alone writes the reservation count in
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.State"; each reservation is released
-- by the send that spends it or given back by the caller that does not. Every
-- operation here is one STM transaction over that count and the handoff's
-- port.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Reservation
  ( Reservation (..)
  , reserveEvent
  , releaseEvent
  , sendReservedEvent
  ) where

import Control.Concurrent.STM (STM, modifyTVar', readTVar, writeTVar)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( EventAdmission
  , TargetEvent
  , handoffEventCapacity
  , offerTargetEvent
  , pendingTargetEvents
  , targetEventsOpen
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..))

-- | What a reservation attempt found.
data Reservation
  = ReservationHeld
  | ReservationFull
    -- ^ The port is open and every place in it is spoken for.
  | ReservationClosed
    -- ^ Admission has ended. Nothing the port carries can be delivered again,
    -- so a caller must not go on to attach something the owner will never
    -- hear of.
  deriving (Eq, Show)

-- | Hold room for one lifetime event, so a handover that cannot be announced
-- is refused before it reserves a window's slot.
--
-- Closure is checked here rather than at the send, because the two answers
-- mean different things to a caller: a full port may have room in a moment
-- and is worth retrying, while a closed one never will. Discovering closure
-- only at the send would mean attaching first and settling afterwards, once
-- per attempt, on an owner that will take no further round.
reserveEvent ∷ GraphicsOwner scene → STM Reservation
reserveEvent owner = do
  open ← targetEventsOpen (ownerHandoff' owner)
  capacity ← handoffEventCapacity (ownerHandoff' owner)
  queued ← pendingTargetEvents (ownerHandoff' owner)
  held ← readTVar (ownerReservations owner)
  if not open
    then pure ReservationClosed
    else
      if queued + held >= capacity
        then pure ReservationFull
        else ReservationHeld <$ writeTVar (ownerReservations owner) (held + 1)

-- | Give back a reservation the caller did not spend.
releaseEvent ∷ GraphicsOwner scene → STM ()
releaseEvent owner = modifyTVar' (ownerReservations owner) (\held → if held == 0 then 0 else held - 1)

-- | Spend a held reservation on one event. The room was held, so this is never
-- refused for fullness; a closed port still refuses.
sendReservedEvent ∷ GraphicsOwner scene → Prepared TargetEvent → STM EventAdmission
sendReservedEvent owner payload = do
  admitted ← offerTargetEvent (ownerHandoff' owner) payload
  releaseEvent owner
  pure admitted
