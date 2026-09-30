-- | Presentation holds: what keeps the graphics owner from presenting to a
-- window the main thread is about to hide (#357).
--
-- A hide's native call can unmap the window's surface, and a compositor need
-- not answer a presentation made for a surface it no longer shows. Under
-- Mesa's legacy FIFO on Wayland — Weston 13 offers no @wp_fifo_v1@ — each
-- present waits, with no timeout, for the frame callback the previous one
-- requested, and Weston sends none for an unmapped surface: the owner's next
-- present to that window would never return. The engine learns that a window
-- was hidden only from the observation the main thread publishes after the
-- call, which is too late. So before the host makes the call, the window's
-- attachment protocol asks for a hold ('withholdPresentation'), on the main
-- thread:
--
-- 1. the hold is recorded against the attachment, bound to the observation
--    revision already published for it;
-- 2. the main thread then waits while the step in flight, if any, may present
--    to that target, and no longer. Every later step reads the hold in the
--    transaction that reads its inputs, so none of them presents to it.
--
-- The owner's step applies the holds ('applyWithholding'). It views a held
-- target as suspended until it has folded an observation newer than the
-- hold's bound — the hidden window's own observation is one — and raises the
-- target's withdrawal count, which the backend reads: whatever the target
-- presented to before the hide must not be presented to again, since its last
-- presentation may never be answered. It prunes a hold once it is obsolete or
-- names an attachment the owner holds no custody of, so the table is bounded
-- by the attachments the owner holds.
--
-- A step must return finitely and the owner never waits for the main thread,
-- so the main thread waits for one step at most. It never waits for an idle
-- owner, one still starting, or one whose step cannot present to the window.
--
-- Main thread: 'withholdPresentation' and the lift it answers. Owner thread:
-- 'applyWithholding' and 'endStepPresenting', inside its step.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Withhold
  ( withholdPresentation
  , applyWithholding
  , endStepPresenting
  ) where

import Control.Concurrent.STM (STM, atomically, check, modifyTVar', readTVar, stateTVar, writeTVar)
import Control.Monad (join)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.GLFW.Internal.Attachment (AttachmentId)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (TargetObservation (targetRevision), readTargetObservations)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( GraphicsOwner (..)
  , TargetState (..)
  , Withheld (..)
  )

-- | Hold the owner's presentation to one target before its window is hidden,
-- on the main thread. It returns once no step in flight may present to the
-- target, and answers the action that lifts the hold again, for a hide that
-- made no native call.
--
-- The wait is interruptible; an interrupted one leaves the hold standing,
-- which only keeps the target suspended until a newer observation arrives.
withholdPresentation ∷ GraphicsOwner scene → AttachmentId → IO (IO ())
withholdPresentation owner target = do
  hold ← atomically $ do
    observations ← readTargetObservations (ownerHandoff' owner)
    request ← stateTVar (ownerWithholdRequests owner) (\asked → (asked + 1, asked + 1))
    let hold = Withheld request (maybe 0 targetRevision (join (lookup target observations)))
    modifyTVar' (ownerWithheld owner) (Map.insert target hold)
    pure hold
  atomically (readTVar (ownerPresenting owner) >>= check . Set.notMember target)
  -- Only this hold is lifted: a later one asked for the same target stands.
  pure . atomically $
    modifyTVar' (ownerWithheld owner) (Map.update (\held → if held == hold then Nothing else Just held) target)

-- | Apply the standing holds to the step about to be offered, in the
-- transaction that reads its inputs, on the owner thread: raise each held
-- target's withdrawal count, prune the holds that are obsolete or unowned,
-- record the targets the step may present to, and answer the ones it views as
-- suspended.
--
-- Every hold is counted by the first step that finds it, even one it finds
-- obsolete, so a hide and a show that both came between two steps still reach
-- the backend as a withdrawal.
applyWithholding ∷ GraphicsOwner scene → STM (Set AttachmentId)
applyWithholding owner = do
  held ← readTVar (ownerWithheld owner)
  states ← readTVar (ownerTargets owner)
  custody ← readTVar (ownerCustody owner)
  let standing target hold = case Map.lookup target states of
        Just state → targetSeen state <= withheldBound hold
        -- Announced and not yet taken: it stands until the owner holds it.
        Nothing → Map.member target custody
      kept = Map.filterWithKey standing held
      suspended = Map.keysSet (Map.intersection kept states)
      raise target state = case Map.lookup target held of
        Just hold → state {targetWithdrawals = max (targetWithdrawals state) (withheldRequest hold)}
        Nothing → state
  writeTVar (ownerWithheld owner) kept
  writeTVar (ownerTargets owner) (Map.mapWithKey raise states)
  writeTVar (ownerPresenting owner) (Map.keysSet states `Set.difference` suspended)
  pure suspended

-- | The step has returned: it presents to nothing now.
endStepPresenting ∷ GraphicsOwner scene → STM ()
endStepPresenting owner = writeTVar (ownerPresenting owner) Set.empty
