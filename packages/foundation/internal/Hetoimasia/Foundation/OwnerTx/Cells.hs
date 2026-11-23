{-# LANGUAGE RoleAnnotations #-}

-- | The cells ownership transactions read and write, and the safe operations over them that need no transaction: an
-- owner cell, the read-only capability over it, and a revisioned publication, each a variable this module owns the
-- representation of, with the reads a waiting reader makes in ordinary 'STM' and the writes a publication's source makes
-- in its own transaction (whose prepared-value installation the public module defines over these constructors, since
-- 'Hetoimasia.Foundation.Messaging.Payload.Prepared' is the main library's).
--
-- It does not import the transaction's representation, so nothing here can make or run an ownership transaction. The
-- cells' constructors stay in this private library: the public module ("Hetoimasia.Foundation.OwnerTx") exports the
-- types abstractly, and the STM-free transaction operations over them are "Hetoimasia.Foundation.OwnerTx.Operations".
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.OwnerTx.Cells
  ( -- * Owner cells
    OwnerCell (..)
  , newCellIO

    -- * Read-only capabilities
  , ReadOnly (..)
  , readOnly
  , watch

    -- * Published facts
  , Publisher (..)
  , Publication (..)
  , publication
  , watchPublication
  ) where

import Control.Concurrent.STM (STM, TVar, newTVarIO, readTVar)
import Data.Word (Word64)

-- | A cell its issuer owns: read and replaced only in ownership transactions.
newtype OwnerCell a = OwnerCell (TVar a)
  deriving newtype (Eq)

-- | A capability to read one owner's cell. Equal only to a capability over the same cell.
newtype ReadOnly a = ReadOnly (TVar a)
  deriving newtype (Eq)

-- | The source's capability over a published fact: its revision and its value, written together. Its payload's role is
-- nominal, as a snapshot endpoint's is: a publisher of one type is never coerced to a publisher of another whose
-- 'Control.DeepSeq.NFData' instance prepares less.
type role Publisher nominal

data Publisher a = Publisher !(TVar Word64) !(TVar a)

-- | What readers of a published fact hold. Its payload's role is nominal for the same reason.
type role Publication nominal

data Publication a = Publication !(TVar Word64) !(TVar a)

instance Eq (Publication a) where
  Publication left _ == Publication right _ = left == right

-- | A fresh cell holding this value, forced to weak head normal form, outside any transaction.
newCellIO ∷ a → IO (OwnerCell a)
newCellIO value = value `seq` (OwnerCell <$> newTVarIO value)

-- | The read-only capability over a cell, for its owner to hand to readers.
readOnly ∷ OwnerCell a → ReadOnly a
readOnly (OwnerCell cell) = ReadOnly cell

-- | Read through the capability in an ordinary transaction, which may wait on it. Never part of a commit.
watch ∷ ReadOnly a → STM a
watch (ReadOnly cell) = readTVar cell

-- | What the source hands to readers.
publication ∷ Publisher a → Publication a
publication (Publisher revision cell) = Publication revision cell

-- | The published revision and value in an ordinary transaction, which may wait on them. Never part of a commit.
watchPublication ∷ Publication a → STM (Word64, a)
watchPublication (Publication revision cell) = (,) <$> readTVar revision <*> readTVar cell
