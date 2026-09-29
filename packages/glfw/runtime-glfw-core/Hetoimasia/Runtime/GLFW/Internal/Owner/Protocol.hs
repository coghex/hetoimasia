-- | The attachment protocol every owner target is registered under, and its
-- one bounded main-thread step.
--
-- The protocol's construction runs on the main thread inside the host's
-- attach and only records the incarnation in the custody ledger; its step runs
-- on the main thread inside the host's retirement drain and performs no owner
-- work. It transports facts an owner terminal record already holds, settles an
-- incarnation nobody was told about, and otherwise waits or stalls.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Protocol
  ( graphicsTargetProtocol
  ) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM, when)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Runtime.GLFW.Internal
  ( Acknowledgement
  , AttachmentId
  , AttachmentProtocol (..)
  , CompletionPolicy (FiniteCompletion)
  , FactAnswer (..)
  , RetirementProgress (..)
  , RollbackOutcome (RollbackSafe)
  , WindowHost
  , allRetirementFacts
  , certifyGraphicsFact
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (recordRegistered)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( OwnerStatus (statusNextDeadline)
  , OwnerTerminal (ownerRunEnded)
  , ownerTerminal
  , readOwnerStatus
  , recordPublishedFact
  , targetTerminal
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Stranded (retireStranded)

-- | The protocol the main thread registers for an owner target.
--
-- 'handOverGraphicsTarget' registers it. It is public for the caller that
-- attaches through 'Hetoimasia.Runtime.GLFW.attachWindowGraphics' itself and
-- announces afterwards: an attachment registered under any other protocol is
-- one the owner can never publish evidence for, because the acknowledgement
-- it would publish under was given to that other protocol.
--
-- Its step performs no owner work, which is exactly D-33's rule for the main
-- thread: it reports what the owner has published and waits. It establishes no
-- retirement fact of its own — the evidence is the owner's — and it certifies
-- one only to transport a fact the owner's own terminal record already holds
-- and the completion publisher could not carry.
graphicsTargetProtocol ∷ WindowHost → GraphicsOwner scene → AttachmentProtocol
graphicsTargetProtocol host owner =
  AttachmentProtocol
    { -- Construction is the owner's, on the owner's thread. Registering the
      -- attachment here — before the owner has built anything — is what makes
      -- the window's slot, and therefore the window itself, retained from the
      -- first instant.
      protocolConstruct = \target acknowledgement →
        atomically (recordRegistered owner target acknowledgement)
    , protocolRollback = pure RollbackSafe
    , protocolStep = \target acknowledgement → ownerAwaitStep host owner target acknowledgement
    , protocolCompletion = FiniteCompletion
    , protocolDisposition = Required
    , protocolRecognizes = \_ → pure False
    }

-- | One bounded main-thread opportunity for an owner target.
--
-- It returns at once, having done no owner work:
--
-- * when the owner has written this target's terminal record, the step
--   /transports/ the facts that record establishes, on the owner thread, and
--   nothing more. It establishes nothing: the evidence existed before the step
--   ran, and a record is only ever written by the owner against what an
--   injected operation returned. It offers every one of them each time,
--   because the completion publisher's admission says only that the transport
--   took a notice — a notice offered before the attachment began retiring is
--   admitted and then refused by the model, so "admitted" is never proof the
--   model holds the fact. A duplicate is answered as one and changes nothing;
--   the step advances only when something was really recorded;
-- * an owner whose run has ended without this target's record leaves no
--   progress path at all, so the step stalls: the window, the session, and
--   every parent stay retained, and only independent evidence revives it;
-- * otherwise it waits, naming the owner's own published deadline when it has
--   one so a running scheduled loop is not delayed past it.
ownerAwaitStep
  ∷ WindowHost → GraphicsOwner scene → AttachmentId → Acknowledgement → IO RetirementProgress
ownerAwaitStep host owner target acknowledgement = do
  record ← atomically (targetTerminal (ownerHandoff' owner) target)
  case record of
    Just _ → do
      answers ← forM allRetirementFacts $ \fact → do
        answered ← certifyGraphicsFact host acknowledgement fact
        when (isJust answered) (atomically (recordPublishedFact (ownerHandoff' owner) target fact))
        pure answered
      pure (if any recorded answers then RetirementAdvanced else RetirementAwaiting)
    Nothing → do
      -- No record, so the owner has established nothing for this target. If
      -- the ledger still says nobody was ever told about it — an
      -- announcement refused, or a close that won before one was made — then
      -- nothing of the owner's exists for it and this step settles it. It is
      -- the same claim every other path makes and under the same condition,
      -- and having it here is what makes it a backstop: a retirement the
      -- main thread began without a release of its own arrives here and
      -- nowhere else.
      settled ← retireStranded host owner target
      if settled
        then pure RetirementAdvanced
        else atomically $ do
          terminal ← ownerTerminal (ownerHandoff' owner)
          status ← readOwnerStatus (ownerHandoff' owner)
          pure $
            if ownerRunEnded terminal
              then RetirementStalled
              else maybe RetirementAwaiting RetirementAwaitingUntil (statusNextDeadline status)
  where
    recorded = \case
      Just (FactRecorded _) → True
      Just AttachmentNowRetired → True
      _ → False
