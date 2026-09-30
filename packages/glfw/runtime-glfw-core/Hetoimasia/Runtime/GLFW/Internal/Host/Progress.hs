-- | What a protected host publishes about its attachments' retirement: the
-- retirement demand the owner loops pace themselves by, and the observation
-- cell each retained 'Hetoimasia.Runtime.GLFW.Internal.Graphics.GraphicsService'
-- reads.
--
-- Both are derived state. The attachment model in
-- "Hetoimasia.Runtime.GLFW.Internal.Retirement" is the authority; this module
-- only brings the host's two published views of it up to date, in the same
-- transaction as whatever changed the model. The bounded round of retirement
-- opportunities runs on the owner thread; every other operation here is an STM
-- step its caller commits, on whichever thread that caller runs. An ordinary
-- host owns no retirement state, and every operation here leaves it exactly as
-- it found it.
module Hetoimasia.Runtime.GLFW.Internal.Host.Progress
  ( -- * The retirement demand
    hostRetirementDemand
  , markRetirementImmediate
  , demandRetirementNow
  , resettleRetirementDemand
  , advanceHostRetirements

    -- * The graphics cells
  , refreshGraphicsCells
  , refreshCells
  , releaseEarlierCell
  , slotOf
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', readTVar, writeTVar)
import Control.Monad (forM_, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.GLFW.Internal.Attachment (AttachmentId, AttachmentPhase (..), attachmentIncarnation, attachmentWindow)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal.Graphics
  ( GraphicsCell
  , GraphicsObservation (..)
  , SlotState (..)
  , readGraphicsCell
  , writeGraphicsSlot
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.State (RetirementDemand (..), WindowHost (..))
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( HostRetirement
  , ProgressRound (..)
  , advanceRetirements
  , anyRetiring
  , retirementStanding
  , windowAttachmentState
  )

hostRetirementDemand ∷ WindowHost → STM RetirementDemand
hostRetirementDemand = readTVar . hostRetirementDemandState

-- | Record that a retirement wants an opportunity now.
--
-- Every round republishes the demand from its own accounting, so this is only
-- ever read by the turn that follows a transaction the round did not see: one
-- that began a retirement, or one that recorded a retirement fact on the owner
-- thread — which is exactly the turn that would otherwise wait its idle bound
-- before offering that attachment the opportunity it is owed. It says so only
-- when something really is retiring, so an ordinary host, and a protected host
-- with nothing pending, report no demand at all.
markRetirementImmediate ∷ WindowHost → STM ()
markRetirementImmediate host =
  demandRetirementNow (hostRetirementState host) (hostRetirementDemandState host)

demandRetirementNow ∷ Maybe HostRetirement → TVar RetirementDemand → STM ()
demandRetirementNow held owed = case held of
  Nothing → pure ()
  Just retirement → do
    retiring ← anyRetiring retirement
    when retiring (modifyTVar' owed (\demand → demand {retirementImmediate = True}))

-- | Answer the published demand's two scheduling questions from what the
-- registrations now say, for a transaction that changed them between two
-- rounds.
--
-- Only the two the owner loops actually pace themselves by. The counts stay the
-- last round's own accounting, which is what they are documented to report, and
-- a refusal count cannot be recomputed from retained state at all.
--
-- Both are replaced rather than widened, because evidence that retires an
-- attachment withdraws the reasons for hurrying as readily as evidence that
-- revives one creates them: an attachment that has just retired is waiting on
-- nothing and is owed nothing, and carrying either answer forward would pace
-- the next turn by an attachment that no longer exists. Nothing the last round
-- or this window said is lost by that. A retirement begun since the round is
-- registered, progressing, and has never been offered an opportunity, so the
-- standing reports it owed on its own; a round that advanced an attachment
-- which is still pending left it wanting another opportunity, so the standing
-- reports that too; and a round that advanced one to completion has nothing
-- left to offer an opportunity to and released its window in that same turn.
resettleRetirementDemand ∷ WindowHost → STM ()
resettleRetirementDemand host = case hostRetirementState host of
  Nothing → pure ()
  Just retirement → do
    (owed, next) ← retirementStanding retirement
    modifyTVar'
      (hostRetirementDemandState host)
      (\demand → demand {retirementImmediate = owed, retirementNextPossible = next})

-- | Offer one bounded, rotating round of retirement opportunities, and publish
-- what it left owed. An ordinary host has no attachment state and does nothing
-- at all here.
advanceHostRetirements ∷ WindowHost → IO ()
advanceHostRetirements host = case hostRetirementState host of
  Nothing → pure ()
  Just retirement → do
    round' ←
      advanceRetirements retirement (hostRetireCursor host) (hostRetirementBudget (hostSettings host))
    atomically $ do
      refreshGraphicsCells host
      writeTVar (hostRetirementDemandState host) (demandOf round')

demandOf ∷ ProgressRound → RetirementDemand
demandOf round' =
  RetirementDemand
    { retirementPending = roundPending round'
    , retirementStalled = roundStalled round'
    , retirementRefused = roundRefused round'
    , retirementImmediate = roundAdvanced round' > 0 || roundOwed round' > 0
    , retirementNextPossible = roundNextPossible round'
    }

-- | Bring every cell the host holds up to what the model now says about its
-- window's slot.
--
-- A cell whose incarnation no longer holds the slot is finalized as free: it
-- has retired, or a later incarnation replaced it, and either way this one owes
-- nothing more. The disposal a cell already carries is never overwritten here;
-- only the window's own retirement writes one.
refreshGraphicsCells ∷ WindowHost → STM ()
refreshGraphicsCells host = refreshCells (hostRetirementState host) (hostGraphicsCells host)

-- | 'refreshGraphicsCells' over the two pieces alone, for the admission-closing
-- release, which is installed before the host value it belongs to exists.
refreshCells ∷ Maybe HostRetirement → TVar (Map WindowId GraphicsCell) → STM ()
refreshCells held slots = case held of
  Nothing → pure ()
  Just retirement → do
    cells ← readTVar slots
    forM_ (Map.toList cells) $ \(window, cell) → do
      observed ← readGraphicsCell cell
      occupant ← windowAttachmentState retirement window
      case occupant of
        Just (identity, phase, missing)
          | attachmentIncarnation identity == observedIncarnation observed →
              writeGraphicsSlot cell (slotOf phase) missing
        _ → writeGraphicsSlot cell SlotFree []

slotOf ∷ AttachmentPhase → SlotState
slotOf = \case
  AttachmentRegistering → SlotAttached
  AttachmentActive → SlotAttached
  AttachmentRetiring → SlotRetiring
  AttachmentRetired → SlotFree

-- | Stop holding the cell of an incarnation this window's slot has moved past.
--
-- It is finalized as free and then dropped, so the window's own disposal, which
-- belongs to whichever incarnation is its last, can never be written into it.
-- It runs in the transaction that reserves the later incarnation, so every
-- reservation settles it — including one that then fails, rolls back, or is
-- cancelled without ever publishing a service.
releaseEarlierCell ∷ WindowHost → AttachmentId → STM ()
releaseEarlierCell host identity = do
  cells ← readTVar (hostGraphicsCells host)
  forM_ (Map.lookup window cells) $ \cell → do
    observed ← readGraphicsCell cell
    when (observedIncarnation observed < attachmentIncarnation identity) $ do
      writeGraphicsSlot cell SlotFree []
      writeTVar (hostGraphicsCells host) (Map.delete window cells)
  where
    window = attachmentWindow identity
