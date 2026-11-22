-- | Ownership transactions: the transactions that commit an owner's facts, with no caller code inside them.
--
-- An 'OwnerTx' is abstract. What this module offers to build one is closed: allocating, reading and replacing
-- 'OwnerCell's by value, reading a 'ReadOnly' capability or a 'Publication' another owner issued, and pure sequencing.
-- 'commit' runs one atomically. Nothing here lifts an 'STM' or 'IO' action into one, waits or retries inside one, throws
-- from one, runs one as part of a larger 'STM' transaction, or takes a function to run inside one: a commit built from
-- this module runs only reads and writes of values its caller has already made.
--
-- __Issuers.__ An issuer (a subsystem that owns state and exports ownership operations over it) keeps its own 'STM' and
-- its existing state, and embeds a concrete operation through
-- 'Hetoimasia.Foundation.OwnerTx.Issuer.fromIssuerSTM', in the @owner-tx-issuer@ sublibrary of this package. Only the
-- components and modules @tools/validation/owner_tx_issuers.json@ lists may import that bridge; the repository's import
-- guard (@tools/validation/owner_tx_guard.py@) refuses any other importer, any unlisted dependency on the sublibrary and
-- any re-export of the bridge or the representation. Every embedded path must:
--
-- * read only issuer-controlled inputs (its own cells and those it was handed by value or by an opaque handle it
--   issued), never a caller's transaction, callback or reader;
-- * validate every guard before its first write;
-- * answer a refusal as data;
-- * finish without waiting ('retry') and without raising.
--
-- GHC checks the public types; review and each issuer's outcome tests check those four properties inside the issuer,
-- its callees included.
--
-- __Values.__ A cell's write forces the value to weak head normal form. A value that must be fully evaluated crosses
-- into a commit 'Prepared': a publication accepts nothing else.
--
-- __Waiting.__ A reader that must wait for a change waits outside every commit: 'watch' and 'watchPublication' read
-- in an ordinary 'STM' transaction, where it may retry, and the reader then asks for a fresh decision in a commit of its
-- own.
--
-- __Publications.__ A fact an independent source owns and a commit only verifies (a lease's liveness, a window's
-- showing, a device's end) is published. The source prepares the value in 'IO', then installs it and advances the
-- revision in its own transaction, the one that changes the fact (its teardown included), even when the value is equal
-- to the last. A commit reads the 'Publication' and never writes it. A publication is not an owner cell.
--
-- __State.__ The module owns none. A cell belongs to the issuer that allocated it, which exports operations on opaque
-- handles and never the cell; a 'ReadOnly' or a 'Publication' is a capability its owner hands to readers.
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
  , watchPublication
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', newTVar, newTVarIO, readTVar, writeTVar)
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import Hetoimasia.Foundation.OwnerTx.Representation (OwnerCell (..), OwnerTx (..), Publication (..), Publisher (..), ReadOnly (..))

-- | Run one ownership transaction atomically. It never waits.
commit ∷ OwnerTx a → IO a
commit (OwnerTx transaction) = atomically transaction

-- | A fresh cell holding this value, forced to weak head normal form.
newCell ∷ a → OwnerTx (OwnerCell a)
newCell value = value `seq` OwnerTx (OwnerCell <$> newTVar value)

-- | A fresh cell holding this value, forced to weak head normal form, outside any transaction.
newCellIO ∷ a → IO (OwnerCell a)
newCellIO value = value `seq` (OwnerCell <$> newTVarIO value)

-- | The cell's value.
readCell ∷ OwnerCell a → OwnerTx a
readCell (OwnerCell cell) = OwnerTx (readTVar cell)

-- | Replace the cell's value by this one, forced to weak head normal form.
writeCell ∷ OwnerCell a → a → OwnerTx ()
writeCell (OwnerCell cell) value = value `seq` OwnerTx (writeTVar cell value)

-- | The read-only capability over a cell, for its owner to hand to readers.
readOnly ∷ OwnerCell a → ReadOnly a
readOnly (OwnerCell cell) = ReadOnly cell

-- | Read through the capability inside a commit.
readTx ∷ ReadOnly a → OwnerTx a
readTx (ReadOnly cell) = OwnerTx (readTVar cell)

-- | Read through the capability in an ordinary transaction, which may wait on it. Never part of a commit.
watch ∷ ReadOnly a → STM a
watch (ReadOnly cell) = readTVar cell

-- | A fresh publisher of a prepared value, at revision 0, in the source's transaction. The handle is selected (forced to
-- weak head normal form, which for a prepared value is all of it, so no 'Control.DeepSeq.NFData' instance runs again)
-- before anything is made: a selection that fails raises here, in the source's transaction.
newPublisher ∷ Prepared a → STM (Publisher a)
newPublisher value = installed value `seq` (Publisher <$> newTVar 0 <*> newTVar (installed value))

-- | A fresh publisher of a prepared value, at revision 0, outside any transaction, the handle selected first.
newPublisherIO ∷ Prepared a → IO (Publisher a)
newPublisherIO value = installed value `seq` (Publisher <$> newTVarIO 0 <*> newTVarIO (installed value))

-- | Install a prepared value and advance the revision, together, in the source's own transaction: the one that changes
-- the fact it publishes, a teardown included. The revision advances even for a value equal to the last. The handle is
-- selected before either is written, so a selection that fails raises in the source's transaction and leaves the prior
-- value and revision as they were.
publish ∷ Publisher a → Prepared a → STM ()
publish (Publisher revision cell) value = installed value `seq` (writeTVar cell (installed value) >> modifyTVar' revision (+ 1))

-- The prepared value a handle carries. Forcing it forces the handle's selection, never the value's preparation again: a
-- prepared value is already fully evaluated.
installed ∷ Prepared a → a
installed = preparedValue

-- | What the source hands to readers.
publication ∷ Publisher a → Publication a
publication (Publisher revision cell) = Publication revision cell

-- | The published revision and value, read together inside a commit. It never waits.
readPublication ∷ Publication a → OwnerTx (Word64, a)
readPublication (Publication revision cell) = OwnerTx ((,) <$> readTVar revision <*> readTVar cell)

-- | The published revision and value in an ordinary transaction, which may wait on them. Never part of a commit.
watchPublication ∷ Publication a → STM (Word64, a)
watchPublication (Publication revision cell) = (,) <$> readTVar revision <*> readTVar cell
