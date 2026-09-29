-- | Settling, on the main thread, an attachment the owner was never told
-- about.
--
-- Main thread alone. It is the one path on which the main thread certifies a
-- target's retirement facts itself, and the custody ledger's claim is what
-- makes that safe: only an incarnation still at 'CustodyRegistered' — no
-- announcement queued, none admissible — can be settled here. The handover,
-- the release and the attachment protocol's step all settle through it.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Stranded
  ( retireUnannounced
  , retireStranded
  , forgetStrandedCustody
  , recoverableTarget
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Exception (mask_)
import Control.Monad (forM, forM_, unless, void, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, listToMaybe)
import GHC.Stack (HasCallStack)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW.Internal
  ( AttachmentId
  , DetachAnswer (..)
  , GraphicsService
  , WindowHost
  , allRetirementFacts
  , attachmentWindow
  , certifyGraphicsFact
  , detachWindowGraphics
  , graphicsAttachment
  , windowGraphicsService
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (advanceCustody, claimSettlement, recordSettled)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (Custody (..), GraphicsOwner (..), Stage (..))

-- | Retire an attachment the owner never received, on the owner thread.
--
-- It is the one case where the main thread establishes a target's retirement
-- facts itself, and the ledger is what makes it safe: 'claimSettlement'
-- answers only for an incarnation still at 'CustodyRegistered', which is
-- exactly the stage at which no announcement is queued and none can be
-- admitted afterwards. So the owner never received this attachment, never
-- entered its construction, and owns nothing for it — there is no backend
-- work to have ended, and leaving it retiring would retain its window
-- against a retirement nothing was ever going to perform.
--
-- An incarnation the owner does owe — announced, or held — answers nothing
-- here and is left to the owner, whose own drain retires it. Absence from
-- the owner's target table is never consulted, because a queued announcement
-- the owner has not yet taken looks exactly like an attachment it never
-- received.
retireUnannounced ∷ HasCallStack ⇒ WindowHost → GraphicsOwner scene → GraphicsService → IO Bool
retireUnannounced host owner service = do
  answered ← detachWindowGraphics host service
  -- An attachment already retiring — a close, a quiescence, or an earlier
  -- detach got there first — is owed its facts exactly as one this call began
  -- is. Only an absent one is owed nothing, because there is nothing left.
  if answered == DetachAbsent
    then pure False
    else retireStranded host owner (graphicsAttachment service)

-- | Settle an attachment the owner never received, naming it by identity, and
-- answer whether this call was the one that settled it.
retireStranded ∷ HasCallStack ⇒ WindowHost → GraphicsOwner scene → AttachmentId → IO Bool
retireStranded host owner target = mask_ $
  -- Masked from the claim through the facts, so a cancellation cannot leave
  -- the ledger claimed with nothing recorded. Every step is a finite,
  -- non-retrying transaction or an owner-thread certification, so nothing
  -- here can block. The claim is retryable besides, which is what makes that
  -- belt as well as braces.
  atomically (claimSettlement owner target) >>= \case
    Nothing → pure False
    Just acknowledgement → do
      -- Its retirement has to have begun before a fact can be recorded at
      -- all: 'certifyGraphicsFact' refuses one for an attachment that is
      -- still active. A settlement that ignored that refusal would mark the
      -- ledger terminal with nothing recorded and stall the drain for good.
      retiring ← atomically (elem target <$> ownerRetiring owner)
      unless retiring (beginStrandedRetirement host target)
      answers ← forM allRetirementFacts (certifyGraphicsFact host acknowledgement)
      atomically $ do
        pending ← ownerPending owner
        let gone = target `notElem` pending
        if gone || all isJust answers
          then do
            recordSettled owner target
            -- Forgotten here rather than at some later owner round: the
            -- entry is owed to nobody, and the owner whose round would
            -- otherwise prune it may be one that never takes another.
            when gone (modifyTVar' (ownerCustody owner) (Map.delete target))
            pure True
          else do
            -- Nothing was recorded, so nothing was settled. It goes back to
            -- where it was, and the paths that may announce or settle it are
            -- free to try again.
            advanceCustody owner target CustodyRegistered
            pure False

-- | Begin the retirement of an attachment nobody has begun, so its facts can
-- be recorded.
--
-- The service is asked of the host rather than held, because an attachment
-- whose answer was lost has one the caller never received. An incarnation the
-- window's slot has moved past is not this one and is left alone.
beginStrandedRetirement ∷ HasCallStack ⇒ WindowHost → AttachmentId → IO ()
beginStrandedRetirement host target =
  atomically (windowGraphicsService host (attachmentWindow target)) >>= \case
    Just service | graphicsAttachment service == target → void (detachWindowGraphics host service)
    _ → pure ()

-- | Forget every ledger entry this window left behind that names no
-- attachment the host still has pending and no target the owner holds.
forgetStrandedCustody ∷ GraphicsOwner scene → WindowId → STM ()
forgetStrandedCustody owner window = do
  entries ← Map.keys <$> readTVar (ownerCustody owner)
  held ← readTVar (ownerTargets owner)
  pending ← ownerPending owner
  forM_
    [ target
    | target ← entries
    , attachmentWindow target == window
    , not (Map.member target held)
    , target `notElem` pending
    ]
    (\target → modifyTVar' (ownerCustody owner) (Map.delete target))

-- | The attachment this window's slot holds that the owner has not been told
-- about, if there is one.
--
-- It is found from the ledger rather than from a published service, because
-- an attachment interrupted before its service was published has no service
-- and still needs its retirement evidence produced. Only an incarnation the
-- ledger still says nobody was told about is a candidate: one already
-- announced is the owner's, and one already settled needs nothing.
recoverableTarget ∷ GraphicsOwner scene → WindowId → STM (Maybe AttachmentId)
recoverableTarget owner window = do
  entries ← Map.toList <$> readTVar (ownerCustody owner)
  pending ← ownerPending owner
  pure $
    listToMaybe
      [ target
      | (target, custody) ← entries
      , custodyStage custody == CustodyRegistered
      , attachmentWindow target == window
      , target `elem` pending
      ]
