-- | The custody ledger's transitions: who owes one attachment incarnation's
-- settlement, and the only operations that move it between 'Stage's.
--
-- The ledger is one cell of the owner handle in
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.State", which defines 'Custody' and
-- 'Stage'. Every operation here is a single STM transaction. The main thread
-- registers an incarnation, claims and settles one the owner was never told
-- about, and admits its announcement; the owner thread records that it has
-- taken one and that its terminal record exists. Any thread may read.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Custody
  ( recordRegistered
  , advanceCustody
  , custodyOf
  , readOwnerCustody
  , claimSettlement
  , recordSettled
  , custodyAcknowledgementOf
  ) where

import Control.Concurrent.STM (STM, modifyTVar', readTVar)
import qualified Data.Map.Strict as Map
import Hetoimasia.GLFW.Internal.Attachment (Acknowledgement, AttachmentId)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State
  ( Custody (..)
  , GraphicsOwner (ownerCustody)
  , Stage (..)
  )

-- | Record an attachment the host has just registered under this owner's
-- protocol. It is never replaced: an incarnation is registered once.
recordRegistered ∷ GraphicsOwner scene → AttachmentId → Acknowledgement → STM ()
recordRegistered owner target acknowledgement =
  modifyTVar'
    (ownerCustody owner)
    (Map.insertWith (\_ existing → existing) target (Custody acknowledgement CustodyRegistered))

-- | Move one incarnation to a later stage, if it has an entry at all.
advanceCustody ∷ GraphicsOwner scene → AttachmentId → Stage → STM ()
advanceCustody owner target stage =
  modifyTVar' (ownerCustody owner) (Map.adjust (\held → held {custodyStage = stage}) target)

-- | The stage one incarnation stands at, or 'Nothing' once it has been
-- forgotten. Any thread may read it; it is the transition state the whole
-- handoff is decided by.
custodyOf ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Stage)
custodyOf owner target = fmap custodyStage . Map.lookup target <$> readTVar (ownerCustody owner)

-- | Every incarnation the ledger still holds, with its stage.
readOwnerCustody ∷ GraphicsOwner scene → STM [(AttachmentId, Stage)]
readOwnerCustody owner = Map.toAscList . Map.map custodyStage <$> readTVar (ownerCustody owner)

-- | Claim the right to settle an owner-unseen attachment on the main thread.
--
-- It answers the acknowledgement only for an incarnation the owner does not
-- owe — one still at 'CustodyRegistered', or one at 'CustodySettling' whose
-- earlier claim did not finish — and moves it to 'CustodySettling' in the
-- same transaction.
--
-- That claim, not the settlement, is what excludes an announcement: settling
-- an attachment means certifying its facts against the host, which is not a
-- transaction and cannot be one, so the stage the claim commits has to hold
-- the exclusion for however long the certification takes. An announcement
-- admitted before this commits leaves the stage at 'CustodyAnnounced' and
-- this answers nothing; one attempted while the claim is held finds
-- 'CustodySettling' and is refused, as is one attempted after the settlement
-- finished and reached 'CustodySettled'.
--
-- The claim is therefore /retryable/ rather than terminal. 'recordSettled'
-- is what makes it terminal, and only once the facts really exist; a claim
-- that could not certify them all puts the stage back at
-- 'CustodyRegistered', so a later opportunity can settle the attachment
-- instead of leaving it claimed by a settlement that never happened.
--
-- Absence from the owner's target table is never consulted, because a queued
-- announcement the owner has not yet taken looks exactly like an attachment
-- it never received.
claimSettlement ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Acknowledgement)
claimSettlement owner target = do
  held ← Map.lookup target <$> readTVar (ownerCustody owner)
  case held of
    -- 'CustodySettling' is claimable too, so a settlement interrupted between
    -- its claim and its facts can be performed again. Nothing else may be:
    -- an announced or owned incarnation is the owner's, and a settled one is
    -- finished.
    Just custody | custodyStage custody `elem` [CustodyRegistered, CustodySettling] → do
      advanceCustody owner target CustodySettling
      pure (Just (custodyAcknowledgement custody))
    _ → pure Nothing

-- | Record that an incarnation's retirement evidence now exists.
recordSettled ∷ GraphicsOwner scene → AttachmentId → STM ()
recordSettled owner target = advanceCustody owner target CustodySettled

-- | The acknowledgement one incarnation is settled under.
custodyAcknowledgementOf ∷ GraphicsOwner scene → AttachmentId → STM (Maybe Acknowledgement)
custodyAcknowledgementOf owner target =
  fmap custodyAcknowledgement . Map.lookup target <$> readTVar (ownerCustody owner)
