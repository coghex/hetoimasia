-- | Ownership transactions: the only way an owner's cells change, and a vocabulary that admits no code but the
-- issuers' own.
--
-- An 'OwnerTx' is built from three things and nothing else: allocating, reading and replacing 'OwnerCell's;
-- reading a 'ReadOnly' capability another owner issued over one of its cells; and pure sequencing. 'commit' runs one
-- atomically. There is no way to lift an 'STM' or 'IO' action into one, to wait or retry inside one, to throw from
-- one, or to run one as part of a larger 'STM' transaction, so a commit runs only the reads and writes its issuers
-- wrote, and it neither blocks nor raises (beyond what a value forced inside it raises: values are written forced,
-- so a commit's issuer forces only what it built).
--
-- __Discipline.__ A compound transition reads and validates every guard before it writes, and answers a refusal as
-- a value. Writes force the written value to weak head normal form; a value that must be fully evaluated crosses
-- into a commit 'Hetoimasia.Foundation.Messaging.Payload.Prepared'.
--
-- __Waiting.__ A reader that must wait for a change waits outside every commit: 'watch' reads a 'ReadOnly' in an
-- ordinary 'STM' transaction, where it may retry, and then asks the owner for a fresh decision in a commit of its
-- own.
--
-- __Published facts.__ A fact an independent source owns, which a commit only verifies (a lease's liveness, a
-- window's showing, a device's end), is published: the source writes a 'Publisher' in its own transaction, fully
-- evaluated, and a commit reads the 'Publication'. A publication is never an owner cell, and no commit writes one.
--
-- __State.__ The module owns none. Each cell is owned by the issuer that allocated it, which exports operations on
-- opaque handles and never the cell itself; a 'ReadOnly' is a capability the issuer hands out to readers.
module Hetoimasia.Foundation.OwnerTx
  ( -- * Transactions
    OwnerTx
  , commit

    -- * Owner cells
  , OwnerCell
  , newCell
  , newCellIO
  , readCell
  , writeCell
  , modifyCell
  , stateCell

    -- * Read-only capabilities
  , ReadOnly
  , readOnly
  , readTx
  , watch

    -- * Published facts
  , Publisher
  , Publication
  , newPublisher
  , newPublisherIO
  , publish
  , publication
  , readPublication
  , publicationRevision
  , watchPublication
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, writeTVar)
import Control.DeepSeq (NFData, force, rnf)
import Control.Exception (evaluate)
import Data.Word (Word64)

-- | One ownership transaction, run by 'commit'.
newtype OwnerTx a = OwnerTx (STM a)
  deriving newtype (Functor, Applicative, Monad)

-- | Run one ownership transaction atomically. It never waits.
commit ∷ OwnerTx a → IO a
commit (OwnerTx transaction) = atomically transaction

-- | A cell its issuer owns: read and replaced only in ownership transactions.
newtype OwnerCell a = OwnerCell (TVar a)
  deriving newtype (Eq)

-- | A fresh cell holding this value.
newCell ∷ a → OwnerTx (OwnerCell a)
newCell value = value `seq` OwnerTx (OwnerCell <$> newTVar value)

-- | A fresh cell holding this value, outside any transaction.
newCellIO ∷ a → IO (OwnerCell a)
newCellIO value = value `seq` (OwnerCell <$> newTVarIO value)

readCell ∷ OwnerCell a → OwnerTx a
readCell (OwnerCell cell) = OwnerTx (readTVar cell)

-- | Replace the cell's value, forced to weak head normal form.
writeCell ∷ OwnerCell a → a → OwnerTx ()
writeCell (OwnerCell cell) value = value `seq` OwnerTx (writeTVar cell value)

-- | Replace the cell's value by a function of it, forced to weak head normal form.
modifyCell ∷ OwnerCell a → (a → a) → OwnerTx ()
modifyCell cell change = readCell cell >>= writeCell cell . change

-- | Replace the cell's value by a function of it that also answers.
stateCell ∷ OwnerCell a → (a → (b, a)) → OwnerTx b
stateCell cell change = do
  (answer, value) ← change <$> readCell cell
  writeCell cell value
  pure answer

-- | A capability to read one owner's cell. Equal only to a capability over the same cell.
newtype ReadOnly a = ReadOnly (TVar a)
  deriving newtype (Eq)

-- | The read-only capability over a cell.
readOnly ∷ OwnerCell a → ReadOnly a
readOnly (OwnerCell cell) = ReadOnly cell

-- | Read through the capability inside an ownership transaction.
readTx ∷ ReadOnly a → OwnerTx a
readTx (ReadOnly cell) = OwnerTx (readTVar cell)

-- | Read through the capability in an ordinary transaction, which may wait on it. Never part of a commit.
watch ∷ ReadOnly a → STM a
watch (ReadOnly cell) = readTVar cell

-- | A fact an independent source owns and publishes, with its revision, for commits to verify. The source keeps the
-- 'Publisher' and writes it in its own transactions, in the one that changes the fact; readers hold the
-- 'Publication', which a commit reads and never writes.
data Publisher a = Publisher !(TVar Word64) !(TVar a)

-- | What readers of a published fact hold. Equal only to the publication of the same publisher.
data Publication a = Publication !(TVar Word64) !(TVar a)

instance Eq (Publication a) where
  Publication left _ == Publication right _ = left == right

-- | A fresh publisher of this value, fully evaluated, at revision 0.
newPublisher ∷ NFData a ⇒ a → STM (Publisher a)
newPublisher value = rnf value `seq` (Publisher <$> newTVar 0 <*> newTVar value)

-- | A fresh publisher of this value, fully evaluated, at revision 0, outside any transaction.
newPublisherIO ∷ NFData a ⇒ a → IO (Publisher a)
newPublisherIO value = do
  forced ← evaluate (force value)
  Publisher <$> newTVarIO 0 <*> newTVarIO forced

-- | Publish a new value, fully evaluated, and move the revision, in the source's own transaction. A value whose
-- evaluation raises raises here, in the publishing transaction, and the publication keeps its prior value.
publish ∷ NFData a ⇒ Publisher a → a → STM ()
publish (Publisher revision cell) value = rnf value `seq` (writeTVar cell value >> modifyTVar' revision (+ 1))

-- | What readers hold.
publication ∷ Publisher a → Publication a
publication (Publisher revision cell) = Publication revision cell

-- | The published value, inside an ownership transaction. It never waits.
readPublication ∷ Publication a → OwnerTx a
readPublication (Publication _ cell) = OwnerTx (readTVar cell)

-- | The publication's revision, inside an ownership transaction.
publicationRevision ∷ Publication a → OwnerTx Word64
publicationRevision (Publication revision _) = OwnerTx (readTVar revision)

-- | The published value and its revision in an ordinary transaction, which may wait on them. Never part of a commit.
watchPublication ∷ Publication a → STM (Word64, a)
watchPublication (Publication revision cell) = (,) <$> readTVar revision <*> readTVar cell
