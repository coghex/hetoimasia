-- | The evidence the graphics owner's injected backend operations return.
--
-- Values only: this module owns no state and runs on no thread. Every record
-- here is constructed by a backend's own operation, on the owner thread, and
-- the owner stores and hands it back without interpreting it. No data
-- constructor is exported, even within @runtime-glfw-core@: a backend builds a
-- record through its smart constructor, and the owner reads one only through
-- 'HasEvidence'.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence
  ( OwnerReady
  , ownerReady
  , TargetEvidence
  , targetEvidence
  , RollbackEvidence
  , rollbackEvidence
  , TargetRetired
  , targetRetired
  , OwnerRetired
  , ownerRetired
  , OwnerDestroyed
  , ownerDestroyed
  , HasEvidence (..)
  ) where

import Data.Text (Text)

-- | What a backend operation established, as the owner records it.
--
-- Its representation is a label the backend chose. The owner stores it, hands
-- it back, and never interprets it — and, which is the whole point, never
-- constructs one: a record that exists is a record an injected operation
-- returned. What the label /says/ is the backend's business; that there /is/
-- one is the permission.
newtype OwnerReady = OwnerReady Text
  deriving (Eq, Show)

newtype TargetEvidence = TargetEvidence Text
  deriving (Eq, Show)

newtype RollbackEvidence = RollbackEvidence Text
  deriving (Eq, Show)

newtype TargetRetired = TargetRetired Text
  deriving (Eq, Show)

newtype OwnerRetired = OwnerRetired Text
  deriving (Eq, Show)

newtype OwnerDestroyed = OwnerDestroyed Text
  deriving (Eq, Show)

ownerReady ∷ Text → OwnerReady
ownerReady = OwnerReady

targetEvidence ∷ Text → TargetEvidence
targetEvidence = TargetEvidence

rollbackEvidence ∷ Text → RollbackEvidence
rollbackEvidence = RollbackEvidence

targetRetired ∷ Text → TargetRetired
targetRetired = TargetRetired

ownerRetired ∷ Text → OwnerRetired
ownerRetired = OwnerRetired

ownerDestroyed ∷ Text → OwnerDestroyed
ownerDestroyed = OwnerDestroyed

-- | The label one piece of evidence carries, so a record can be quoted in a
-- diagnostic without anything learning to interpret it.
class HasEvidence a where
  evidenceDetail ∷ a → Text

instance HasEvidence OwnerReady where evidenceDetail (OwnerReady detail) = detail

instance HasEvidence TargetEvidence where evidenceDetail (TargetEvidence detail) = detail

instance HasEvidence RollbackEvidence where evidenceDetail (RollbackEvidence detail) = detail

instance HasEvidence TargetRetired where evidenceDetail (TargetRetired detail) = detail

instance HasEvidence OwnerRetired where evidenceDetail (OwnerRetired detail) = detail

instance HasEvidence OwnerDestroyed where evidenceDetail (OwnerDestroyed detail) = detail
