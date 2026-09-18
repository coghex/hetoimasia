-- | The public face of an exclusive window attachment: the opaque service an
-- application holds, and the observation it and its workers may read from any
-- thread.
--
-- "Hetoimasia.GLFW.Internal.Attachment" is the pure model and
-- "Hetoimasia.Runtime.GLFW.Internal.Retirement" the boundary that owns one.
-- Neither is public. This module is the narrow layer between them and an
-- application: it names no graphics API, holds no native pointer, no window
-- handle, no session, and no destruction, release, or completion authority, and
-- it makes no native call.
--
-- = The service
--
-- 'GraphicsService' is what a successful attachment hands back. Its
-- representation is private and it carries exactly two things: the attachment
-- identity the host recognizes it by, and one retained observation cell. It is
-- not a capability over the window, the session, or the attachment's
-- dependents: detaching goes back through the host, which holds the
-- acknowledgement, and nothing here can destroy anything.
--
-- A service is published only once construction and registration have both
-- completed, so a value of this type never names an attachment that is still
-- being built.
--
-- = The observation
--
-- 'GraphicsObservation' answers, without inference, which incarnation held the
-- slot, whether an owner is attached, retiring, or gone, which of the model's
-- retirement facts are still missing, and whether the window's native
-- destruction has completed. A close ticket's
-- 'Hetoimasia.GLFW.Command.WindowCloseBegun' still says nothing about any of
-- them.
--
-- Each attachment has one cell, made when it is reserved and written only by
-- the owner thread. A retained service keeps its cell after the host has
-- forgotten the window, so a terminal retirement and a terminal disposal stay
-- readable; the host holds at most one cell per window it still has, so
-- repeated detaching and reattaching grows no incarnation history it owns.
--
-- A service observes the native disposal of its window when its own
-- incarnation was that window's last: an incarnation the slot moved on from
-- keeps 'SlotFree' with the disposal its own lifetime ended with, because the
-- destruction that followed belonged to a later owner. The host stops holding a
-- cell as soon as a later reservation of the same window succeeds — whatever
-- becomes of that reservation, including one that rolls back or is superseded
-- without ever publishing a service — so a disposal can never be credited to an
-- incarnation the slot has moved past.
--
-- = State
--
-- +----------------------+------------------+--------------------------------+--------+-------------------+--------------------------------+
-- | State                | Owner            | Readers and writers            | Thread | Lifetime          | Reset or disposal              |
-- +======================+==================+================================+========+===================+================================+
-- | An attachment's      | The protected    | The owner thread writes; any   | Write: | The service value | Finalized when its incarnation |
-- | observation cell     | host lifetime    | holder of the service reads    | owner; | that retains it   | leaves the slot and when its   |
-- |                      |                  |                                | read:  |                   | window is disposed; never      |
-- |                      |                  |                                | any    |                   | reopened                       |
-- +----------------------+------------------+--------------------------------+--------+-------------------+--------------------------------+
module Hetoimasia.Runtime.GLFW.Internal.Graphics
  ( -- * The opaque service
    GraphicsService
  , graphicsWindow
  , graphicsAttachment
  , graphicsIncarnation

    -- * Observation
  , GraphicsObservation (..)
  , SlotState (..)
  , NativeDisposal (..)
  , WindowGraphics (..)
  , readGraphicsService

    -- * The cell, for the boundary that owns it
  , GraphicsCell
  , newGraphicsCell
  , readGraphicsCell
  , writeGraphicsSlot
  , writeGraphicsDisposal
  , serviceFor
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVar, readTVar)
import Hetoimasia.GLFW.Internal.Attachment
  ( AttachmentId
  , RetirementFact
  , attachmentIncarnation
  , attachmentWindow
  )
import Hetoimasia.GLFW.Window (WindowId)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Observation

-- | Where an incarnation stands in its window's one exclusive slot.
data SlotState
  = SlotAttached
    -- ^ The owner holds the slot and new use is admitted.
  | SlotRetiring
    -- ^ No new use may begin; the retirement facts are being established.
  | SlotFree
    -- ^ This incarnation has retired and the slot is free for a later one.
  deriving (Eq, Show)

-- | Whether the window's own native destruction has happened, kept distinct
-- from the attachment's retirement: a retired attachment stops vetoing
-- destruction, and the host's close protocol and ordinary borrows then decide.
data NativeDisposal
  = DisposalPending
    -- ^ The host still holds the window, or it was never this incarnation's to
    -- see.
  | DisposalCompleted
  | DisposalFailed
    -- ^ The release failed. The collection latched that failure as evidence for
    -- its own exit and never attempts it again; nothing here reports a
    -- successful destruction because of it.
  deriving (Eq, Show)

-- | One incarnation's state, readable from any thread.
data GraphicsObservation = GraphicsObservation
  { observedIncarnation ∷ !Natural
    -- ^ Which incarnation this observation is about. Incarnations start at one
    -- and are never reissued.
  , observedSlot ∷ !SlotState
  , observedMissing ∷ ![RetirementFact]
    -- ^ The retirement facts still owed, empty once the attachment retired.
  , observedDisposal ∷ !NativeDisposal
  }
  deriving (Eq, Show)

-- | What a window's exclusive slot holds, as the host reads it now.
data WindowGraphics
  = GraphicsAbsent
    -- ^ The host holds the window and no owner is attached to it.
  | GraphicsPresent !GraphicsObservation
  | GraphicsWindowUnknown
    -- ^ The host holds no window with this identity, so it has no slot at all.
    -- A retained 'GraphicsService' still answers for its own incarnation.
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The cell

-- | One attachment's observation, written by the owner thread alone.
newtype GraphicsCell = GraphicsCell (TVar GraphicsObservation)
  deriving (Eq)

-- | A cell for an incarnation that has just reserved its window's slot.
newGraphicsCell ∷ Natural → [RetirementFact] → STM GraphicsCell
newGraphicsCell incarnation missing =
  GraphicsCell <$> newTVar (GraphicsObservation incarnation SlotAttached missing DisposalPending)

readGraphicsCell ∷ GraphicsCell → STM GraphicsObservation
readGraphicsCell (GraphicsCell cell) = readTVar cell

-- | Record where the incarnation stands and what it still owes.
writeGraphicsSlot ∷ GraphicsCell → SlotState → [RetirementFact] → STM ()
writeGraphicsSlot (GraphicsCell cell) slot missing =
  modifyTVar' cell (\observed → observed {observedSlot = slot, observedMissing = missing})

-- | Record what the window's own release settled as.
writeGraphicsDisposal ∷ GraphicsCell → NativeDisposal → STM ()
writeGraphicsDisposal (GraphicsCell cell) disposal =
  modifyTVar' cell (\observed → observed {observedDisposal = disposal})

-- ---------------------------------------------------------------------------
-- The opaque service

-- | What an application holds for one attached graphics owner.
--
-- It names the attachment and retains its observation, and nothing else. It is
-- no native pointer, no window, no session, and no authority to destroy,
-- release, or certify anything.
data GraphicsService = GraphicsService !AttachmentId !GraphicsCell

-- | The identity alone, never the cell: two services are the same service when
-- they name the same incarnation of the same window of the same host.
instance Eq GraphicsService where
  GraphicsService left _ == GraphicsService right _ = left == right

instance Show GraphicsService where
  showsPrec precedence (GraphicsService target _) =
    showParen (precedence > 10) (showString "GraphicsService " . showsPrec 11 target)

-- | Make the service for an established attachment. Only the boundary that
-- registered it may call this; nothing public does.
serviceFor ∷ AttachmentId → GraphicsCell → GraphicsService
serviceFor = GraphicsService

-- | The window whose exclusive slot this service holds, or held. It is an
-- identity the host resolves, never a handle: it carries no native pointer and
-- no authority over the window.
graphicsWindow ∷ GraphicsService → WindowId
graphicsWindow (GraphicsService target _) = attachmentWindow target

-- | The attachment this service names.
graphicsAttachment ∷ GraphicsService → AttachmentId
graphicsAttachment (GraphicsService target _) = target

-- | Which incarnation of the window's slot it is. Never reissued, so an
-- acknowledgement or a report naming an earlier one is refused.
graphicsIncarnation ∷ GraphicsService → Natural
graphicsIncarnation (GraphicsService target _) = attachmentIncarnation target

-- | This incarnation's own observation, from any thread. It stays readable
-- after the host has forgotten the window.
readGraphicsService ∷ GraphicsService → STM GraphicsObservation
readGraphicsService (GraphicsService _ cell) = readGraphicsCell cell
