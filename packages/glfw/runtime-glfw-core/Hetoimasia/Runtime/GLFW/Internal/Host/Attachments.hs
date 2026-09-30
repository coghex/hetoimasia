-- | The public attachment contract: attaching a graphics owner to one open
-- window of a protected host, detaching it, and observing the window's one
-- exclusive graphics slot.
--
-- Attach and detach run on the process main thread, the session's owner, and
-- refuse other threads; the observations answer on any thread in one
-- transaction. The slot and its retirement are the host's attachment model,
-- owned by "Hetoimasia.Runtime.GLFW.Internal.Retirement"; the observation
-- cells an application's services read are the host's, kept current by
-- "Hetoimasia.Runtime.GLFW.Internal.Host.Progress". What this module adds is
-- the protected region that makes reservation, construction, and publication
-- one step, and the answers an application is handed.
module Hetoimasia.Runtime.GLFW.Internal.Host.Attachments
  ( GraphicsAttachment (..)
  , GraphicsRefusal (..)
  , attachWindowGraphics
  , detachWindowGraphics
  , windowGraphicsStatus
  , windowGraphicsService
  , hostGraphicsPublisher
  , certifyGraphicsFact
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Exception (ExceptionWithContext, SomeException, mask, rethrowIO, tryWithContext)
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentId
  , AttachmentPhase (..)
  , AttachmentRefusal
  , FactAnswer
  , RetirementFact
  , activeAttachment
  , allRetirementFacts
  , attachmentIncarnation
  , attachmentWindow
  )
import qualified Hetoimasia.GLFW.Internal.Attachment as Model
import Hetoimasia.GLFW.Internal.Session (ownerOperation)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Graphics
  ( GraphicsObservation (..)
  , GraphicsService
  , NativeDisposal (..)
  , WindowGraphics (..)
  , graphicsAttachment
  , newGraphicsCell
  , readGraphicsCell
  , serviceFor
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress
  ( markRetirementImmediate
  , refreshGraphicsCells
  , releaseEarlierCell
  , slotOf
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Seam (attachOperation, hostCompletionPublisher, reportHostRetirementFact)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostHooks (..), WindowHost (..), windowIdentifiers)
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( AttachmentOutcome (..)
  , AttachmentProtocol
  , CompletionPublisher
  , DetachAnswer (..)
  , HostRetirement
  , MetadataRejection
  , RolledBack
  , attachRetirement
  , cancelAttachment
  , detachAttachment
  , windowAttachmentState
  )

detachOperation ∷ Operation
detachOperation = operation "detach window graphics"

-- | How a request to attach a graphics owner to a window was answered.
--
-- Every refusal is answered before any acquisition effect, and nothing usable
-- is published before construction and registration have both completed.
data GraphicsAttachment
  = GraphicsAttached !GraphicsService
    -- ^ Construction and registration completed and the opaque service was
    -- published.
  | GraphicsSuperseded !AttachmentId
    -- ^ Retirement had already begun by the time the service would have been
    -- published — the window started closing, or the host quiesced, while the
    -- construction ran or in the handoff after it settled. The dependents stay
    -- registered for retirement and nothing usable was published.
  | GraphicsRolledBack !RolledBack
    -- ^ Construction failed and its owned rollback settled. A rollback that
    -- established safety retired the attachment; one that could not keeps the
    -- window, the exclusive slot, and every dependency it left, with its
    -- original and cleanup evidence, for the protected boundary's own drain.
    -- Nothing usable was published either way.
  | GraphicsRefused !GraphicsRefusal
    -- ^ The reservation was refused before any acquisition effect.
  | GraphicsMetadataRejected !MetadataRejection
    -- ^ A declaration the supplied 'AttachmentProtocol' carries raised when the
    -- boundary demanded it, which it does before it reserves anything. No slot
    -- was reserved, no protocol registered, no construction entered, and no
    -- rollback run — there is no attachment to name — and the failure is handed
    -- back with the context it propagated with.
  | GraphicsHostUnprotected
    -- ^ The host was built with the @Scoped@ constructor, so it owns no
    -- retirement state and was issued no identity an attachment could name.
    -- Answered before any effect, and before the owner thread is even checked
    -- against anything the host holds.
  deriving (Show)

-- | Why a window's exclusive graphics slot was not reserved.
--
-- Every one of these is answered before the owner's construction is entered, so
-- a refusal has acquired nothing, published nothing, and left the window's slot
-- exactly as it found it.
data GraphicsRefusal
  = GraphicsWindowClosing !WindowId
    -- ^ The window's close protocol has begun, so no new graphics use may
    -- start on it.
  | GraphicsWindowUnavailable !WindowId
    -- ^ This host holds no such open window, so there is no slot of its to
    -- reserve. It may be a window of another host of the same session, or one
    -- of this host's own that has ended; the two are one answer deliberately,
    -- because telling them apart would need a record of every window this host
    -- ever held, and this boundary keeps nothing that grows with how many
    -- windows were ever made. A window of another /session/ is named as such,
    -- because a session identity is carried by the window itself.
  | GraphicsWindowOccupied !AttachmentId
    -- ^ Another owner holds the window's one exclusive slot, and holds it until
    -- it has safely retired.
  | GraphicsForeignSession
    -- ^ The window belongs to another session.
  | GraphicsAdmissionEnded
    -- ^ Attachment admission has closed — the host has quiesced or is exiting —
    -- so no new graphics use may begin at all.
  | GraphicsSlotUnavailable
    -- ^ The reservation was refused for a reason a reservation is not expected
    -- to produce. Nothing was acquired and nothing changed.
  deriving (Eq, Show)

refusalOf ∷ AttachmentRefusal → GraphicsRefusal
refusalOf = \case
  Model.WindowIsClosing window → GraphicsWindowClosing window
  Model.WindowNotRegistered window → GraphicsWindowUnavailable window
  Model.WindowHasEnded window → GraphicsWindowUnavailable window
  Model.WindowOccupied occupant → GraphicsWindowOccupied occupant
  Model.AttachmentMisuse Model.ForeignSession → GraphicsForeignSession
  _ → GraphicsSlotUnavailable

-- | Attach a graphics owner to one open window of a protected host, on the
-- owner thread.
--
-- The owner is the caller's: it supplies the construction of the dependents,
-- the bounded retirement step, the completion policy those steps are offered
-- under, and how a failed step is classified. This boundary supplies the
-- exclusivity, the ordering, and the retirement rule, and it hands back only
-- the opaque 'GraphicsService': no native pointer, no window, no session, and
-- no destruction, release, or completion authority.
--
-- The protocol's own declarations — its 'protocolCompletion' and its
-- 'protocolDisposition' — are demanded before anything is reserved, because this
-- boundary reads them itself on every later round. One that raises when it is
-- demanded answers 'GraphicsMetadataRejected' having constructed nothing, and
-- never becomes a failure raised out of a running turn or out of the protected
-- exit's own drain.
--
-- Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner', and a
-- host with no retirement state with 'GraphicsHostUnprotected', each before any
-- effect.
attachWindowGraphics
  ∷ HasCallStack ⇒ WindowHost → WindowId → AttachmentProtocol → IO GraphicsAttachment
attachWindowGraphics host target protocol =
  ownerOperation (hostSession host) attachOperation (windowIdentifiers target) $
    case hostRetirementState host of
      Nothing → pure GraphicsHostUnprotected
      Just retirement →
        -- One protected region covers the reservation, the construction, and
        -- the publication together. The seam's own mask ends when it answers,
        -- and an interruption delivered between there and this answer would
        -- otherwise leave an attachment admitting use that nobody holds a
        -- service to end.
        mask $ \restore → do
          attempted ←
            tryWithContext (attachRetirement retirement restore target protocol (releaseEarlierCell host))
          case attempted of
            Right outcome → do
              answered ← settleAttachment host retirement outcome
              -- Outside 'publishOrRetire''s own handler, so a failure here
              -- leaves the attachment exactly as a published one is: active,
              -- with its caller about to lose the answer.
              case answered of
                GraphicsAttached _ → afterPublication (hostHooks host)
                _ → pure ()
              pure answered
            Left (caught ∷ ExceptionWithContext SomeException) → do
              -- A construction that was cancelled, and a rollback that could not
              -- establish safety, both leave the attachment retiring and
              -- re-raise rather than answering. That retirement has never been
              -- offered an opportunity either, so a caller that catches this and
              -- keeps running must not wait its idle bound before one.
              atomically (markRetirementImmediate host)
              rethrowIO caught

-- | Turn a settled reservation into the public answer, inside the same
-- protected region that made it.
settleAttachment
  ∷ HasCallStack ⇒ WindowHost → HostRetirement → AttachmentOutcome → IO GraphicsAttachment
settleAttachment host retirement = \case
  AttachmentEstablished active _ → publishOrRetire host retirement (activeAttachment active)
  AttachmentSuperseded identity _ → begunRetiring (GraphicsSuperseded identity)
  AttachmentRolledBack settled → begunRetiring (GraphicsRolledBack settled)
  AttachmentRefused refusal → pure (GraphicsRefused (refusalOf refusal))
  AttachmentMetadataRejected rejected → pure (GraphicsMetadataRejected rejected)
  AttachmentAdmissionClosed → pure (GraphicsRefused GraphicsAdmissionEnded)
  AttachmentHostUnprotected → pure GraphicsHostUnprotected
  where
    -- A superseded publication and a retained rollback both leave something
    -- retiring that no turn has offered an opportunity to yet.
    begunRetiring answer = atomically (markRetirementImmediate host) >> pure answer

-- | Publish the established attachment's service, or — if anything interrupts
-- the handoff — begin its retirement before re-raising.
--
-- The window between an attachment becoming active and its caller holding the
-- service is the one place an interruption could strand the exclusive slot: the
-- attachment is registered, its dependents are built, and no service exists to
-- detach it with, while a running turn deliberately offers no opportunity to an
-- attachment that has not begun retiring. So an interruption here is counted as
-- the model's own evidence and begins exactly the retirement a detach begins,
-- and an owner turn then retires it and frees the slot. It establishes no fact,
-- and the failure is re-raised unchanged.
publishOrRetire
  ∷ HasCallStack ⇒ WindowHost → HostRetirement → AttachmentId → IO GraphicsAttachment
publishOrRetire host retirement identity = do
  attempted ← tryWithContext (beforePublication (hostHooks host) >> publishService host identity)
  case attempted of
    Right answered → pure answered
    Left (caught ∷ ExceptionWithContext SomeException) → do
      atomically $ do
        cancelAttachment retirement identity
        refreshGraphicsCells host
        markRetirementImmediate host
      rethrowIO caught


-- | Make the established attachment's observation cell and its service in one
-- transaction, and only while that attachment is still the window's active
-- owner.
--
-- Publication and the check that it is still warranted commit together: a
-- quiescence, a close, or a detach that reached the attachment after its
-- construction settled has already begun its retirement, and this answers
-- 'GraphicsSuperseded' rather than handing an application a service for an
-- owner that may admit no use. The dependents stay registered for retirement
-- exactly as they do when the model supersedes the publication itself.
publishService ∷ WindowHost → AttachmentId → IO GraphicsAttachment
publishService host identity = atomically $ do
  owning ← attachmentStillActive host identity
  if not owning
    then pure (GraphicsSuperseded identity)
    else do
      cell ← newGraphicsCell (attachmentIncarnation identity) allRetirementFacts
      modifyTVar' (hostGraphicsCells host) (Map.insert (attachmentWindow identity) cell)
      refreshGraphicsCells host
      pure (GraphicsAttached (serviceFor identity cell))

-- | Whether this exact attachment still holds its window's slot and still
-- admits new use.
attachmentStillActive ∷ WindowHost → AttachmentId → STM Bool
attachmentStillActive host identity = case hostRetirementState host of
  Nothing → pure False
  Just retirement → do
    occupant ← windowAttachmentState retirement (attachmentWindow identity)
    pure $ case occupant of
      Just (held, phase, _) → held == identity && phase == AttachmentActive
      Nothing → False

-- | Detach a window's current graphics owner while the window stays open, on
-- the owner thread.
--
-- It begins exactly the retirement a close begins, under the same protocol and
-- the same owner turns, and the exclusive slot frees only once every retirement
-- fact is recorded and the owner's dependents are safely disposed. A later
-- attachment then gets a fresh incarnation, against which this one's
-- acknowledgement is refused and releases nothing.
--
-- Detaching an absent or already retiring owner is a typed no-op answer, not a
-- failure. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner', and a host with no retirement
-- state answers 'DetachAbsent'.
detachWindowGraphics ∷ HasCallStack ⇒ WindowHost → GraphicsService → IO DetachAnswer
detachWindowGraphics host service =
  ownerOperation (hostSession host) detachOperation (windowIdentifiers (attachmentWindow target)) $
    case hostRetirementState host of
      Nothing → pure DetachAbsent
      Just retirement → atomically $ do
        answered ← detachAttachment retirement target
        refreshGraphicsCells host
        -- A retirement that has just begun has never been offered an
        -- opportunity, so the next turn polls rather than waiting for one.
        when (answered == DetachBegun) (markRetirementImmediate host)
        pure answered
  where
    target = graphicsAttachment service

-- | What a window's one exclusive graphics slot holds, read in one transaction
-- from any thread.
--
-- It answers without inference: whether an owner is attached, retiring, or
-- absent, which incarnation holds the slot, which retirement facts are still
-- missing, and whether the window's own native destruction has completed. A
-- close ticket's 'Hetoimasia.GLFW.Command.WindowCloseBegun' implies none of
-- them.
windowGraphicsStatus ∷ WindowHost → WindowId → STM WindowGraphics
windowGraphicsStatus host target = case hostRetirementState host of
  Nothing → pure GraphicsWindowUnknown
  Just retirement → do
    held ← Map.member target <$> readTVar (hostEntries host)
    occupant ← windowAttachmentState retirement target
    cells ← readTVar (hostGraphicsCells host)
    case (held, occupant) of
      (False, Nothing) → pure GraphicsWindowUnknown
      (_, Nothing) → pure GraphicsAbsent
      (_, Just (identity, phase, missing)) → do
        disposal ← maybe (pure DisposalPending) (fmap observedDisposal . readGraphicsCell) (Map.lookup target cells)
        pure . GraphicsPresent $
          GraphicsObservation
            { observedIncarnation = attachmentIncarnation identity
            , observedSlot = slotOf phase
            , observedMissing = missing
            , observedDisposal = disposal
            }

-- | The service of the window's current owner, or 'Nothing' when its slot is
-- free, when the host holds no such window, or when the owner's own attachment
-- has not been published yet.
--
-- It builds no new capability: a service is an identity and the observation
-- cell the host already holds for that incarnation, so what comes back here is
-- the very service the attachment published, equal to it and interchangeable
-- with it.
--
-- It exists because a value returned from an operation is not something a
-- runtime can promise to deliver. An interruption can be delivered to the
-- calling thread at the instant 'attachWindowGraphics' restores its masking
-- state — after the attachment is active and its service published, and beyond
-- any handler that operation could install. The attachment is still perfectly
-- reachable; only the caller's copy of the answer was lost. Asking the host by
-- window returns it, so a caller that catches such an interruption and keeps
-- running can always detach what it attached.
windowGraphicsService ∷ WindowHost → WindowId → STM (Maybe GraphicsService)
windowGraphicsService host target = case hostRetirementState host of
  Nothing → pure Nothing
  Just retirement → do
    occupant ← windowAttachmentState retirement target
    cells ← readTVar (hostGraphicsCells host)
    matching ← traverse readGraphicsCell (Map.lookup target cells)
    pure $ do
      (identity, _, _) ← occupant
      cell ← Map.lookup target cells
      observed ← matching
      -- The cell of an incarnation the slot has moved past is dropped when the
      -- later one reserves, so this only ever disagrees when the later
      -- reservation published nothing at all.
      if observedIncarnation observed == attachmentIncarnation identity
        then pure (serviceFor identity cell)
        else Nothing

-- | The capability a thread that is not the owner publishes one certified
-- retirement fact through, or 'Nothing' for a host that owns no attachment
-- state.
--
-- It carries no authority over the model: an admitted notice is revalidated on
-- the owner thread exactly as an owner-thread report is, so one queued for a
-- replaced incarnation is refused when it is folded and touches the replacement
-- not at all. Publishing wakes the owner exactly as a command admission does.
hostGraphicsPublisher ∷ WindowHost → Maybe CompletionPublisher
hostGraphicsPublisher = hostCompletionPublisher

-- | Certify one retirement fact on the owner thread, from inside the owner's
-- own protocol. It is 'reportHostRetirementFact' under the name the public
-- contract uses.
certifyGraphicsFact
  ∷ HasCallStack ⇒ WindowHost → Acknowledgement → RetirementFact → IO (Maybe FactAnswer)
certifyGraphicsFact = reportHostRetirementFact
