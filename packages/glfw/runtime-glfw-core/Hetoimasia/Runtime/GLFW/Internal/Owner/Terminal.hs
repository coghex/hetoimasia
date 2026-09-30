-- | Retiring the targets the owner holds, and publishing and forgetting the
-- terminal records their retirement produced.
--
-- Owner thread alone, in its rounds and in its exit drain. A terminal record
-- is written only against the evidence an injected retirement returned — or a
-- rollback the backend verified — and is the one thing that removes a target
-- from the owner's table. The record is the retention and the host's
-- completion publisher only the transport, so a refused publication leaves
-- the fact owed.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Terminal
  ( retireReleased
  , retireOneTarget
  , publishOwed
  , forgetValidatedTargets
  , validatedTargets
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO)
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , evaluate
  , mask
  , rethrowIO
  , tryWithContext
  )
import Control.Monad (forM_, unless)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentId
  , NoticeAdmission (..)
  , allRetirementFacts
  , attachmentWindow
  , completionNotice
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Custody (recordSettled)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence (HasEvidence (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( TerminalRecord (terminalOwed)
  , closeTargetSlot
  , forgetTargetTerminal
  , recordPublishedFact
  , recordTargetTerminal
  , targetTerminal
  , targetTerminals
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Latch (isAsynchronous, retainFailure)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Operations
  ( GraphicsOperations (..)
  , RetirementReadiness (..)
  , TargetRetire (TargetRetire)
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( Construction (..)
  , Custody (custodyAcknowledgement)
  , GraphicsOwner (..)
  , TargetState (..)
  , constructed
  )
import Hetoimasia.Runtime.GLFW.Internal.Retirement (CompletionPublication (..), publishCompletion)

-- | Retire every target the main thread released, through the injected
-- operation, and record exactly what it returned.
retireReleased ∷ GraphicsOwner scene → IO ()
retireReleased owner = do
  states ← readTVarIO (ownerTargets owner)
  forM_ [entry | entry@(_, state) ← Map.toAscList states, targetReleasing state] (uncurry (retireOneTarget owner))

retireOneTarget ∷ GraphicsOwner scene → AttachmentId → TargetState → IO ()
retireOneTarget _ _ state
  -- Failed once already, so it is not offered again. The target stays in the
  -- owner's table, explicitly unverified, and whole-owner retirement is told
  -- about it by name.
  | targetRetirementFailed state = pure ()
retireOneTarget owner target state = case targetConstruction state of
  -- The backend verified its own rollback, so there is nothing of the owner's
  -- to retire and nothing to ask it for. The rollback evidence it returned is
  -- the terminal record.
  ConstructionRolledBack evidence → settle (evidenceDetail evidence)
  -- Interruptible across the injected call and masked from its return to the
  -- record it commits. The gap matters more here than anywhere: a
  -- cancellation delivered after a /successful/ retirement returned but
  -- before its terminal record existed would leave the target unmarked and
  -- unrecorded, and the drain would offer the operation again — disposing a
  -- second time what the backend has already disposed, which is exactly the
  -- blind retry this design admits nowhere.
  --
  -- It is attempted only once the backend says it can be performed now: a
  -- target whose obligations wait on evidence yet to arrive is asked again at
  -- a later round, and nothing is recorded meanwhile.
  _ →
    tryWithContext (graphicsPrepareRetirement (ownerOperations (ownerSettings owner)) retiring >>= evaluate) >>= \case
      -- A cancellation during the preparation is not a failed retirement: the
      -- preparation disposes of nothing the owner records, so the target
      -- stays owed and the drain asks again.
      Left failure@(ExceptionWithContext _ exception)
        | isAsynchronous exception → rethrowIO failure
      Left failure → do
        atomically
          ( modifyTVar'
              (ownerTargets owner)
              (Map.adjust (\held → held {targetRetirementFailed = True}) target)
          )
        retainFailure owner failure
      Right (RetirementOwed _) → pure ()
      Right RetirementReady → retireNow
  where
    retiring = TargetRetire target (attachmentWindow target) (constructed (targetConstruction state))
    retireNow =
      mask $ \restore →
        tryWithContext
          ( restore
              ( graphicsRetireTarget (ownerOperations (ownerSettings owner)) retiring
                  >>= evaluate
              )
          )
          >>= \case
            -- A failed retirement preserves its evidence and manufactures no
            -- acknowledgement: no record is written, so nothing downstream can
            -- mistake the attempt for the fact, the target stays in the owner's
            -- table, and it is marked so that nothing offers the operation
            -- again.
            Left failure → do
              atomically
                ( modifyTVar'
                    (ownerTargets owner)
                    (Map.adjust (\held → held {targetRetirementFailed = True}) target)
                )
              retainFailure owner failure
            Right retired → ownerSettled owner >> settle (evidenceDetail retired)
    settle evidence = do
      atomically $ do
        recordTargetTerminal (ownerHandoff' owner) target evidence allRetirementFacts
        recordSettled owner target
        modifyTVar' (ownerTargets owner) (Map.delete target)
        -- The geometry is this incarnation's alone and nothing reads it once
        -- the target is retired, so it goes with the target rather than
        -- accumulating one entry per incarnation a window has ever had.
        modifyTVar' (ownerGeometryCells owner) (Map.delete target)
        closeTargetSlot (ownerHandoff' owner) target
      publishTerminal owner target (targetAcknowledgement state)

-- | Offer every fact a terminal record still owes to the host's completion
-- publisher.
--
-- A refusal leaves the fact owed. That is what makes the record the retention
-- and the publisher only the transport: a full inbox delays publication and
-- can never lose a fact.
publishOwed ∷ GraphicsOwner scene → IO ()
publishOwed owner = do
  records ← atomically (targetTerminals (ownerHandoff' owner))
  acknowledgements ← readTVarIO (ownerCustody owner)
  forM_ (Map.toAscList records) $ \(target, record) →
    unless (null (terminalOwed record)) $
      for_ (custodyAcknowledgement <$> Map.lookup target acknowledgements) (publishTerminal owner target)

-- | Offer this target's owed facts once, under the acknowledgement its
-- attachment was given.
publishTerminal ∷ GraphicsOwner scene → AttachmentId → Acknowledgement → IO ()
publishTerminal owner target acknowledgement = do
  held ← atomically (targetTerminal (ownerHandoff' owner) target)
  for_ held $ \record →
    forM_ (terminalOwed record) $ \fact →
      publishCompletion (ownerPublisher owner) (completionNotice target acknowledgement fact) >>= \case
        CompletionOffered NoticeAdmitted → published fact
        -- An equal notice is already pending, so the transport is already
        -- carrying this fact and the record stops owing it.
        CompletionOffered NoticeCoalesced → published fact
        CompletionOffered NoticeRejectedFull → pure ()
        CompletionClosed → pure ()
  where
    published fact = atomically (recordPublishedFact (ownerHandoff' owner) target fact)

-- | Forget the cells of every attachment that has validated the facts its
-- terminal record established.
--
-- An attachment leaves the host's own pending set only once its model holds
-- every retirement fact, so that — and not the owner's own bookkeeping — is
-- what says the record has done its work. A target the owner still holds is
-- never forgotten, however the host's set reads.
--
-- Without this the retained cells would be keyed by incarnation and grow with
-- every detach-and-reattach cycle. With it they are bounded by the windows the
-- host may hold live, which is what the handoff's contract promises.
forgetValidatedTargets ∷ GraphicsOwner scene → IO ()
forgetValidatedTargets owner = atomically $ do
  validated ← validatedTargets owner
  forM_ validated $ \target → do
    forgetTargetTerminal (ownerHandoff' owner) target
    modifyTVar' (ownerCustody owner) (Map.delete target)
    modifyTVar' (ownerGeometryCells owner) (Map.delete target)

-- | The attachments whose cells the owner may now forget.
--
-- Two kinds qualify, and both by the same test: the owner holds the target no
-- longer and the host's own model no longer has the attachment pending.
--
-- One is a target the owner retired and whose record's facts the attachment
-- has since validated. The other never reached the owner at all — a handover
-- interrupted after this protocol recorded its acknowledgement and before the
-- owner was told, whose attach then settled with a safe rollback. It leaves
-- an acknowledgement and no record, so waiting for a record to prune it would
-- keep one per cancelled attempt for the host's whole life.
--
-- An attachment between its registration and its announcement is /pending/,
-- so it is never mistaken for either.
validatedTargets ∷ GraphicsOwner scene → STM [AttachmentId]
validatedTargets owner = do
  records ← Map.keys <$> targetTerminals (ownerHandoff' owner)
  acknowledged ← Map.keys <$> readTVar (ownerCustody owner)
  held ← readTVar (ownerTargets owner)
  pending ← ownerPending owner
  pure
    [ target
    | target ← records <> filter (`notElem` records) acknowledged
    , not (Map.member target held)
    , target `notElem` pending
    ]
