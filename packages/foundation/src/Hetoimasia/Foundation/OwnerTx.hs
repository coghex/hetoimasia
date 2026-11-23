-- | Ownership transactions: the transactions that commit an owner's facts, with no caller 'STM' or 'IO' inside them.
--
-- An 'OwnerTx' is abstract. What this module offers to build one is closed: allocating, reading and replacing
-- 'OwnerCell's by value, reading a 'ReadOnly' capability or a 'Publication' another owner issued, and pure sequencing.
-- 'commit' runs one atomically. Nothing here lifts an 'STM' or 'IO' action into one, waits or retries inside one, throws
-- from one, runs one as part of a larger 'STM' transaction, or takes an effectful function to run inside one.
--
-- Pure sequencing and by-value writes can still evaluate caller expressions during a commit: a continuation may
-- compute a replacement from a cell it just read, and 'writeCell' forces that replacement inside the transaction, so
-- a partial expression there (a missing map lookup, say) raises in 'commit' and rolls the whole transaction back. A
-- caller prepares every fallible input, and decides every refusal, before committing.
--
-- __Issuers.__ An issuer (a subsystem that owns state and exports ownership operations over it) keeps its own 'STM' and
-- its existing state, and embeds a concrete operation through
-- 'Hetoimasia.Foundation.OwnerTx.Issuer.fromIssuerSTM', in the @owner-tx-issuer@ sublibrary of this package. Only issuer
-- components depend on that sublibrary: reviewers check every @build-depends@ that names it, and what the issuer's
-- modules import and export, against the review contract below and in the bridge's own documentation. Every embedded
-- path must:
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
-- __Where it comes from.__ This module imports no protected module: it re-exports the STM-free operations of the
-- private adapter "Hetoimasia.Foundation.OwnerTx.Operations" and the cells' types, kept abstract, with their observation
-- and publication operations from "Hetoimasia.Foundation.OwnerTx.Cells", which does not import the representation.
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

import Control.Concurrent.STM (STM, modifyTVar', newTVar, newTVarIO, writeTVar)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import Hetoimasia.Foundation.OwnerTx.Cells
  ( OwnerCell
  , Publication
  , Publisher (..)
  , ReadOnly
  , newCellIO
  , publication
  , readOnly
  , watch
  , watchPublication
  )
import Hetoimasia.Foundation.OwnerTx.Operations (OwnerTx, commit, newCell, readCell, readPublication, readTx, writeCell)

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
