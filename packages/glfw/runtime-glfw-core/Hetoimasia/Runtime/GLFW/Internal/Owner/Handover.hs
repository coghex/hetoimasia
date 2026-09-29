-- | Handing a target over to the owner: the protected reserve, attach and
-- announce, its recovery when an attachment's answer is lost, and the
-- main-thread observation publication.
--
-- Main thread alone. 'handOverGraphicsTarget' is one masked region over the
-- port reservation, the host attachment and the announcement, restoring only
-- the attachment; its recovery paths stay beside it rather than in separately
-- callable pieces. It is not "Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff":
-- that is the bounded cross-thread publication protocol, and this is the
-- client-side attachment path that publishes into it.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Handover
  ( GraphicsHandover (..)
  , handOverGraphicsTarget
  , announceGraphicsTarget
  , publishGraphicsObservation
  , OwnerHandoverUnsettled (..)
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception
  ( Exception
  , ExceptionWithContext
  , SomeException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.Internal.Attachment (AttachmentId)
import Hetoimasia.GLFW.Window (WindowId, WindowObservation)
import Hetoimasia.Runtime.GLFW.Internal.Graphics (GraphicsService, graphicsAttachment)
import Hetoimasia.Runtime.GLFW.Internal.Host.Attachments
  ( GraphicsAttachment (..)
  , GraphicsRefusal
  , attachWindowGraphics
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.State (WindowHost)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (advanceCustody, custodyAcknowledgementOf, custodyOf)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( EventAdmission (..)
  , ExtentBounds
  , ObservationPublication
  , TargetEvent (..)
  , TargetObservation (..)
  , closeTargetSlot
  , installTargetSlot
  , offerTargetEvent
  , prepareTargetSlot
  , publishTargetObservation
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Protocol (graphicsTargetProtocol)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Reservation (Reservation (..), releaseEvent, reserveEvent)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..), Stage (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Stranded
  ( forgetStrandedCustody
  , recoverableTarget
  , retireStranded
  , retireUnannounced
  )
import Hetoimasia.Runtime.GLFW.Internal.RenderDemand (RenderEligibility)
import Hetoimasia.Runtime.GLFW.Internal.Retirement (RolledBack (rolledBackAttachment))
import Numeric.Natural (Natural)

-- | How a handover settled.
data GraphicsHandover
  = TargetHandedOver !GraphicsService
    -- ^ The window's exclusive slot is reserved, the attachment is registered,
    -- and the owner has been told. The owner constructs the target on its own
    -- thread; its terminal record and the service's observation say what
    -- became of it.
  | HandoverRefused !GraphicsRefusal
    -- ^ The host refused the reservation, before any effect.
  | HandoverPortFull
    -- ^ The owner's bounded lifetime port could not take the event, so nothing
    -- was reserved, attached, or constructed. It is backpressure, reported
    -- here rather than swallowed: the caller may offer the same window again.
  | HandoverOwnerClosed
    -- ^ The owner's admission has ended. Nothing is left attached.
  | HandoverSuperseded !AttachmentId
    -- ^ The host's admission closed while the reservation was being made, so
    -- nothing usable was published. The attachment it left behind has been
    -- retired: the owner never received it and owned nothing for it. It is
    -- named so a caller can see which incarnation that was.
  | HandoverRolledBack !RolledBack
    -- ^ The reservation settled as a rollback, whose attachment — if it left
    -- one — has been retired for the same reason.
  deriving (Show)

-- | Reserve one open window's exclusive graphics slot for the owner, on the
-- main thread, and hand the target over.
--
-- The port's room is held /before/ anything is reserved, so a full port is
-- answered with nothing attached rather than with an attachment the owner was
-- never told about.
handOverGraphicsTarget ∷ WindowHost → GraphicsOwner scene → WindowId → IO GraphicsHandover
handOverGraphicsTarget host owner window =
  -- One protected region covers the reservation, the attachment and the
  -- announcement together. Only the attachment itself is restored, because
  -- only it runs for an unbounded time; everything either side of it is a
  -- finite, non-retrying transaction, so no cancellation can land in the gap
  -- between holding the port's room and spending it, or between reserving the
  -- window's slot and telling the owner about it.
  mask $ \restore → do
    reserved ← atomically (reserveEvent owner)
    case reserved of
      ReservationFull → pure HandoverPortFull
      -- Nothing is attached at all: an owner whose admission has ended will
      -- never hear of anything, so there is nothing to be gained by
      -- reserving a window's slot and settling it again afterwards.
      ReservationClosed → pure HandoverOwnerClosed
      ReservationHeld →
        tryWithContext (restore (attachWindowGraphics host window (graphicsTargetProtocol host owner))) >>= \case
          Left (failure ∷ ExceptionWithContext SomeException) → do
            -- A cancellation delivered inside that call can leave the window's
            -- slot reserved and its protocol registered while the call itself
            -- raises: with the service published and the answer lost, or
            -- retiring with no service ever published. Both leave an
            -- attachment whose retirement evidence only the owner can produce,
            -- so both are announced before this propagates.
            --
            -- The reservation and the protocol's registration commit together
            -- before construction begins, and this protocol's own construction
            -- is one finite transaction, so an attachment that exists at all
            -- has already recorded the acknowledgement this announcement needs.
            recovered ← atomically (recoverableTarget owner window)
            case recovered of
              Just target →
                announceReserved owner target >>= \case
                  EventAdmitted → pure ()
                  -- The owner's admission closed in the same moment — a
                  -- terminal owner failure does that — so it will never hear
                  -- of this attachment and owns nothing for it. Settling it
                  -- here is the difference between a window the host drain
                  -- releases and one it waits on for evidence nobody will
                  -- produce.
                  _ → void (retireStranded host owner target)
              -- Nothing of this window's is pending, so whatever the attach
              -- settled as, it left no attachment. Any acknowledgement this
              -- protocol recorded for it is dropped here rather than at some
              -- later owner round: an owner blocked in its startup or its
              -- step takes no rounds, and one acknowledgement per cancelled
              -- attempt is exactly the unbounded growth the cells must not
              -- have.
              Nothing → atomically (releaseEvent owner >> forgetStrandedCustody owner window)
            rethrowIO failure
          Right (GraphicsAttached service) →
            announceReserved owner (graphicsAttachment service) >>= \case
              EventAdmitted → pure (TargetHandedOver service)
              -- The owner's admission closed between the reservation and the
              -- send, which a terminal owner failure can do at any moment.
              _ → HandoverOwnerClosed <$ void (retireUnannounced host owner service)
          Right (GraphicsRefused refusal) → do
            atomically (releaseEvent owner)
            pure (HandoverRefused refusal)
          -- Quiescence won between the reservation and the publication. The
          -- attachment is registered and retiring, and its acknowledgement is
          -- recorded, but nothing usable was published and the owner was
          -- never told — so the owner owns nothing for it and its facts are
          -- certified here, exactly as an unannounced handover's are. Left
          -- alone it would be an attachment whose evidence nothing was ever
          -- going to produce, and the protected drain would wait for it.
          Right (GraphicsSuperseded target) → do
            atomically (releaseEvent owner)
            void (retireStranded host owner target)
            pure (HandoverSuperseded target)
          -- A construction that failed and rolled back. This protocol's own
          -- construction is one finite transaction that cannot fail, so this
          -- is reachable only through a cancellation inside the reservation;
          -- either way the owner never received the target and owns nothing
          -- for it, and an unsafe rollback leaves it retiring and owed the
          -- same certification.
          Right (GraphicsRolledBack settled) → do
            atomically (releaseEvent owner)
            void (retireStranded host owner (rolledBackAttachment settled))
            pure (HandoverRolledBack settled)
          Right other → do
            atomically (releaseEvent owner)
            throwIO (OwnerHandoverUnsettled (Text.pack (show other)))

-- | Tell the owner about a target, for a caller that attached it through
-- 'Hetoimasia.Runtime.GLFW.attachWindowGraphics' itself, or that must offer
-- the same event again after 'HandoverPortFull'.
announceGraphicsTarget ∷ GraphicsOwner scene → GraphicsService → IO EventAdmission
announceGraphicsTarget owner service = mask_ $ do
  reserved ← atomically (reserveEvent owner)
  case reserved of
    ReservationFull → pure EventRefusedFull
    ReservationClosed → pure EventPortClosed
    ReservationHeld → announceReserved owner (graphicsAttachment service)

-- | Install the target's observation slot, queue its announcement, and spend
-- the held reservation — all in one transaction.
--
-- The whole admission commits together or not at all: the incarnation's stage
-- is checked, the host is asked whether that exact attachment is still one of
-- its own pending ones, the slot is installed, and the event is queued. A
-- delayed announcement for an incarnation the slot has moved past therefore
-- cannot reopen anything, and neither can one racing the main thread's own
-- settlement of the same attachment — whichever transaction commits first
-- decides, and the other is refused.
announceReserved ∷ GraphicsOwner scene → AttachmentId → IO EventAdmission
announceReserved owner target = do
  held ← atomically (custodyAcknowledgementOf owner target)
  case held of
    Nothing → EventPortClosed <$ atomically (releaseEvent owner)
    Just acknowledgement → do
      -- Allocated outside the transaction because a snapshot cannot be made
      -- inside one; discarded unspent if the admission below refuses.
      slot ← prepareTargetSlot
      payload ← prepare (TargetAttached target acknowledgement)
      atomically $ do
        stage ← custodyOf owner target
        pending ← ownerPending owner
        if stage /= Just CustodyRegistered || target `notElem` pending
          then EventPortClosed <$ releaseEvent owner
          else do
            _ ← installTargetSlot (ownerHandoff' owner) target slot
            admitted ← offerTargetEvent (ownerHandoff' owner) payload
            releaseEvent owner
            if admitted == EventAdmitted
              then EventAdmitted <$ advanceCustody owner target CustodyAnnounced
              else admitted <$ closeTargetSlot (ownerHandoff' owner) target

-- | Publish one target's latest observation and render eligibility, from the
-- main thread, as its own monotonic revision.
publishGraphicsObservation
  ∷ GraphicsOwner scene
  → GraphicsService
  → Natural
  → WindowObservation
  → RenderEligibility
  → Maybe ExtentBounds
  → IO ObservationPublication
publishGraphicsObservation owner service revision observation eligibility bounds = do
  payload ← prepare (Just (TargetObservation revision observation eligibility bounds))
  atomically (publishTargetObservation (ownerHandoff' owner) (graphicsAttachment service) payload)

-- | A handover settled as something a handover is not expected to produce.
-- Nothing was left attached.
newtype OwnerHandoverUnsettled = OwnerHandoverUnsettled Text
  deriving (Eq, Show)

instance Exception OwnerHandoverUnsettled
