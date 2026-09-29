-- | Taking one target back from the owner: D-33's individual close, which
-- leaves the owner and every other target live.
--
-- Main thread alone, masked through settlement. It begins the attachment's
-- retirement and tells the owner through a held port reservation, or — for an
-- incarnation the owner was never told about, or one whose owner's admission
-- has ended — settles it through
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.Stranded" when the ledger says
-- nobody else owes it.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Release
  ( ReleaseAnswer (..)
  , releaseGraphicsTarget
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext, SomeException, mask_, rethrowIO, tryWithContext)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Runtime.GLFW.Internal
  ( DetachAnswer (..)
  , GraphicsService
  , WindowHost
  , detachWindowGraphics
  , graphicsAttachment
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (custodyOf)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (EventAdmission (EventAdmitted), TargetEvent (TargetReleased))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Reservation
  ( Reservation (..)
  , releaseEvent
  , reserveEvent
  , sendReservedEvent
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner, Stage (CustodyRegistered))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Stranded (retireStranded)

-- | What a release answered.
data ReleaseAnswer
  = ReleaseBegun
    -- ^ The attachment is retiring and the owner has been told. Its window is
    -- released once the owner's own retirement evidence has been validated;
    -- the owner and every other target stay live.
  | ReleaseSettled
    -- ^ The owner was never told about this incarnation, so there was nothing
    -- to tell it and no room on its port to hold: the attachment is retiring
    -- and its facts were certified here, because nothing of the owner's
    -- exists for it.
  | ReleaseOwnerRetires
    -- ^ The owner owes this incarnation — it was announced, or it holds the
    -- target — and the event could not be delivered, so the owner's own drain
    -- produces its evidence rather than a release event.
  | ReleaseNoOp !DetachAnswer
  | ReleasePortFull
    -- ^ The owner's port could not take the event, so nothing was detached.
  deriving (Show)

-- | Retire one target, leaving the owner and every other target live.
--
-- This is D-33's individual close, not its whole-session exit: nothing here
-- joins the owner, retires it, or destroys anything it shares.
releaseGraphicsTarget ∷ WindowHost → GraphicsOwner scene → GraphicsService → IO ReleaseAnswer
releaseGraphicsTarget host owner service = mask_ $ do
  -- Masked through settlement, so a cancellation can never begin the
  -- attachment's retirement and then fail to tell the owner, which would
  -- leave a retiring attachment whose evidence nothing was going to produce.
  -- Every step is a finite, non-retrying transaction.
  stage ← atomically (custodyOf owner target)
  if stage == Just CustodyRegistered
    then
      -- Nobody was ever told about this incarnation, so there is nothing to
      -- tell and no room to hold for telling it. A port that happens to be
      -- full is not an obstacle to a release that needs no event, and
      -- answering 'ReleasePortFull' here would leave the caller retrying
      -- something it never needed.
      detachWithoutEvent host owner service
    else do
      reserved ← atomically (reserveEvent owner)
      case reserved of
        ReservationFull → pure ReleasePortFull
        -- The owner's admission has ended, so no event can reach it. The
        -- detach still happens: an attachment's retirement has to begin
        -- before any evidence for it can be recorded at all, and the owner's
        -- own drain — or this attachment's protocol step — is what produces
        -- it. Withholding the detach would leave the caller's release
        -- unperformed.
        ReservationClosed → detachWithoutEvent host owner service
        ReservationHeld →
          -- A detach that raises gives the held room back rather than
          -- spending it on an event there is now nothing to send.
          tryWithContext (detachWindowGraphics host service) >>= \case
            Left (failure ∷ ExceptionWithContext SomeException) → do
              atomically (releaseEvent owner)
              rethrowIO failure
            Right DetachBegun → do
              payload ← prepare (TargetReleased target)
              admitted ← atomically (sendReservedEvent owner payload)
              if admitted == EventAdmitted
                then pure ReleaseBegun
                else do
                  -- The retirement has begun and the event could not be
                  -- delivered. The owner owes this incarnation — the ledger
                  -- says it was announced or taken — so its own drain
                  -- produces the evidence; settling it here would be the main
                  -- thread claiming a retirement that is not its to claim.
                  settled ← retireStranded host owner target
                  pure (if settled then ReleaseSettled else ReleaseOwnerRetires)
            Right other → do
              atomically (releaseEvent owner)
              pure (ReleaseNoOp other)
  where
    target = graphicsAttachment service

-- | Begin one attachment's retirement with no event to carry it, and settle
-- it here if the owner was never told about it.
--
-- It is the shape both eventless releases take: the one nobody was told
-- about, and the one whose owner's admission has already ended. The claim is
-- what decides between them, because an announcement can win the race
-- against any stage read that preceded it.
detachWithoutEvent
  ∷ HasCallStack ⇒ WindowHost → GraphicsOwner scene → GraphicsService → IO ReleaseAnswer
detachWithoutEvent host owner service =
  tryWithContext (detachWindowGraphics host service) >>= \case
    Left (failure ∷ ExceptionWithContext SomeException) → rethrowIO failure
    Right DetachAbsent → pure (ReleaseNoOp DetachAbsent)
    Right _ → do
      settled ← retireStranded host owner (graphicsAttachment service)
      pure (if settled then ReleaseSettled else ReleaseOwnerRetires)
